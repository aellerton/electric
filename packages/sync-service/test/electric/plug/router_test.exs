defmodule Electric.Plug.RouterTest do
  @moduledoc """
  Integration router tests that set up entire stack with unique DB.

  Unit tests should be preferred wherever possible because they will run faster.
  """
  use ExUnit.Case

  alias Electric.Replication.LogOffset
  alias Support.DbStructureSetup
  alias Electric.Plug.Router
  alias Support.DbSetup
  alias Electric.Replication.Changes
  import Support.ComponentSetup
  import Plug.Test

  @moduletag :tmp_dir
  @moduletag :capture_log

  @first_offset to_string(LogOffset.first())

  describe "/" do
    test "returns 200" do
      assert %{status: 200, resp_body: ""} = Router.call(conn("GET", "/"), [])
    end
  end

  describe "/nonexistent" do
    test "returns 404" do
      assert %{status: 404, resp_body: "Not found"} = Router.call(conn("GET", "/nonexistent"), [])
    end
  end

  describe "/v1/shapes" do
    setup {DbSetup, :with_unique_db}
    setup {DbStructureSetup, :with_basic_tables}
    setup {DbStructureSetup, :with_sql_execute}

    setup(do: %{publication_name: "electric_test_pub"})

    setup :with_complete_stack

    setup(ctx, do: %{opts: Router.init(build_router_opts(ctx))})

    @tag with_sql: [
           "INSERT INTO items VALUES (gen_random_uuid(), 'test value 1')"
         ]
    test "GET returns a snapshot of initial data", %{opts: opts} do
      conn =
        conn("GET", "/v1/shape/items?offset=-1")
        |> Router.call(opts)

      assert %{status: 200} = conn

      assert [
               %{
                 "headers" => %{"action" => "insert"},
                 "key" => _,
                 "offset" => @first_offset,
                 "value" => %{
                   "id" => _,
                   "value" => "test value 1"
                 }
               },
               %{"headers" => %{"control" => "up-to-date"}}
             ] = Jason.decode!(conn.resp_body)
    end

    test "GET returns an error when table is not found", %{opts: opts} do
      conn =
        conn("GET", "/v1/shape/nonexistent?offset=-1")
        |> Router.call(opts)

      assert %{status: 400} = conn

      assert %{"root_table" => ["table not found"]} = Jason.decode!(conn.resp_body)
    end

    @tag additional_fields: "num INTEGER NOT NULL"
    @tag with_sql: [
           "INSERT INTO items VALUES (gen_random_uuid(), 'test value 1', 1)"
         ]
    test "GET returns values in the snapshot and the rest of the log in the same format (as strings)",
         %{opts: opts, db_conn: db_conn} do
      conn = conn("GET", "/v1/shape/items?offset=-1") |> Router.call(opts)
      assert [%{"value" => %{"num" => "1"}}, _] = Jason.decode!(conn.resp_body)

      Postgrex.query!(
        db_conn,
        "INSERT INTO items VALUES (gen_random_uuid(), 'test value 2', 2)",
        []
      )

      [shape_id] = Plug.Conn.get_resp_header(conn, "x-electric-shape-id")

      conn =
        conn("GET", "/v1/shape/items?shape_id=#{shape_id}&offset=0_0&live") |> Router.call(opts)

      assert [%{"value" => %{"num" => "2"}}, _] = Jason.decode!(conn.resp_body)
    end

    @tag with_sql: [
           "INSERT INTO items VALUES (gen_random_uuid(), 'test value 1')"
         ]
    test "DELETE forces the shape ID to be different on reconnect and new snapshot to be created",
         %{opts: opts, db_conn: db_conn} do
      conn =
        conn("GET", "/v1/shape/items?offset=-1")
        |> Router.call(opts)

      assert %{status: 200} = conn
      assert [shape_id] = Plug.Conn.get_resp_header(conn, "x-electric-shape-id")

      assert [%{"value" => %{"value" => "test value 1"}}, %{"headers" => _}] =
               Jason.decode!(conn.resp_body)

      assert %{status: 202} =
               conn("DELETE", "/v1/shape/items?shape_id=#{shape_id}")
               |> Router.call(opts)

      Postgrex.query!(db_conn, "DELETE FROM items", [])
      Postgrex.query!(db_conn, "INSERT INTO items VALUES (gen_random_uuid(), 'test value 2')", [])

      conn =
        conn("GET", "/v1/shape/items?offset=-1")
        |> Router.call(opts)

      assert %{status: 200} = conn
      assert [shape_id2] = Plug.Conn.get_resp_header(conn, "x-electric-shape-id")
      assert shape_id != shape_id2

      assert [%{"value" => %{"value" => "test value 2"}}, %{"headers" => _}] =
               Jason.decode!(conn.resp_body)
    end

    @tag with_sql: [
           "CREATE TABLE foo (second TEXT NOT NULL, first TEXT NOT NULL, fourth TEXT, third TEXT NOT NULL, PRIMARY KEY (first, second, third))",
           "INSERT INTO foo (first, second, third, fourth) VALUES ('a', 'b', 'c', 'd')"
         ]
    test "correctly snapshots and follows a table with a composite PK", %{
      opts: opts,
      db_conn: db_conn
    } do
      # Request a snapshot
      conn =
        conn("GET", "/v1/shape/foo?offset=-1")
        |> Router.call(opts)

      assert %{status: 200} = conn
      assert [shape_id] = Plug.Conn.get_resp_header(conn, "x-electric-shape-id")

      key =
        Changes.build_key({"public", "foo"}, %{"first" => "a", "second" => "b", "third" => "c"}, [
          "first",
          "second",
          "third"
        ])

      assert [
               %{
                 "headers" => %{"action" => "insert"},
                 "key" => ^key,
                 "offset" => @first_offset,
                 "value" => %{
                   "first" => "a",
                   "second" => "b",
                   "third" => "c",
                   "fourth" => "d"
                 }
               },
               %{"headers" => %{"control" => "up-to-date"}}
             ] = Jason.decode!(conn.resp_body)

      task =
        Task.async(fn ->
          conn("GET", "/v1/shape/foo?offset=#{@first_offset}&shape_id=#{shape_id}&live")
          |> Router.call(opts)
        end)

      # insert a new thing
      Postgrex.query!(
        db_conn,
        "INSERT INTO foo (first, second, third, fourth) VALUES ('e', 'f', 'g', 'h')",
        []
      )

      conn = Task.await(task)

      assert %{status: 200} = conn

      key2 =
        Changes.build_key({"public", "foo"}, %{"first" => "e", "second" => "f", "third" => "g"}, [
          "first",
          "second",
          "third"
        ])

      assert [
               %{
                 "headers" => %{"action" => "insert"},
                 "key" => ^key2,
                 "offset" => _,
                 "value" => %{
                   "first" => "e",
                   "second" => "f",
                   "third" => "g",
                   "fourth" => "h"
                 }
               },
               %{"headers" => %{"control" => "up-to-date"}}
             ] = Jason.decode!(conn.resp_body)
    end
  end
end