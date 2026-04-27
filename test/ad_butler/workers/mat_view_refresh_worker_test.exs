defmodule AdButler.Workers.MatViewRefreshWorkerTest do
  use AdButler.DataCase, async: false

  alias AdButler.Workers.MatViewRefreshWorker

  setup do
    on_exit(fn -> Application.delete_env(:ad_butler, :analytics_refresh_fn) end)
  end

  defp stub_refresh(result) do
    Application.put_env(:ad_butler, :analytics_refresh_fn, fn _period -> result end)
  end

  describe "perform/1" do
    test "delegates to refresh fn with '7d' and returns :ok" do
      stub_refresh(:ok)
      job = build_job(%{"view" => "7d"})
      assert :ok = MatViewRefreshWorker.perform(job)
    end

    test "delegates to refresh fn with '30d' and returns :ok" do
      stub_refresh(:ok)
      job = build_job(%{"view" => "30d"})
      assert :ok = MatViewRefreshWorker.perform(job)
    end

    test "passes the period to the refresh fn" do
      test_pid = self()

      Application.put_env(:ad_butler, :analytics_refresh_fn, fn period ->
        send(test_pid, {:refresh_called, period})
        :ok
      end)

      MatViewRefreshWorker.perform(build_job(%{"view" => "7d"}))
      assert_receive {:refresh_called, "7d"}
    end

    test "returns {:error, _} for unknown view" do
      Application.delete_env(:ad_butler, :analytics_refresh_fn)
      job = build_job(%{"view" => "unknown_view"})
      assert {:error, "unknown view: unknown_view"} = MatViewRefreshWorker.perform(job)
    end

    test "propagates {:error, reason} from refresh fn" do
      stub_refresh({:error, "timeout"})
      job = build_job(%{"view" => "7d"})
      assert {:error, "timeout"} = MatViewRefreshWorker.perform(job)
    end
  end

  defp build_job(args) do
    %Oban.Job{args: args}
  end
end
