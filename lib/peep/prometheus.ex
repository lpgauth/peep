defmodule Peep.Prometheus do
  @moduledoc """
  Prometheus exporter module.

  If your application handles calls to "GET /metrics", your handler can call:

      Peep.get_all_metrics(:my_peep) // Replace with your Peep reporter name
      |> Peep.Prometheus.export()
  """

  alias Telemetry.Metrics.{Counter, Distribution, LastValue, Sum}

  def export(metrics) do
    metrics
    |> Enum.map(&format/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.intersperse(?\n)
    |> then(fn io -> [io, ?\n] end)
  end

  defp format({%Counter{}, _series} = metric) do
    format_standard(metric, "counter")
  end

  defp format({%Sum{}, _series} = metric) do
    format_standard(metric, "counter")
  end

  defp format({%LastValue{}, _series} = metric) do
    format_standard(metric, "gauge")
  end

  defp format({%Distribution{} = metric, tagged_series}) do
    name = format_name(metric.name)
    help = "# HELP #{name} #{escape_help(metric.description)}"
    type = "# TYPE #{name} histogram"

    distributions =
      Enum.map_intersperse(tagged_series, ?\n, fn {tags, buckets} ->
        format_distribution(name, tags, buckets)
      end)

    Enum.intersperse([help, type, distributions], ?\n)
  end

  defp format_distribution(name, tags, buckets) do
    has_labels? = length(tags) > 0

    buckets_as_floats =
      Map.delete(buckets, :sum)
      |> Enum.map(fn {bucket_string, count} -> {String.to_float(bucket_string), count} end)
      |> Enum.sort()

    {prefix_sums, count} = prefix_sums(buckets_as_floats)

    {labels, label_prefix, label_joiner, label_suffix} =
      if has_labels? do
        {format_labels(tags), "{", ",", "}"}
      else
        {"", "", "", ""}
      end

    samples =
      Enum.sort(prefix_sums)
      |> Enum.map_intersperse(?\n, fn {upper_bound, count} ->
        ~s(#{name}_bucket{#{labels}#{label_joiner}le="#{upper_bound}"} #{count})
      end)

    sum = Map.get(buckets, :sum, 0)

    summary =
      [
        ~s(#{name}_bucket{#{labels}#{label_joiner}le="+Inf"} #{count}),
        ~s(#{name}_sum#{label_prefix}#{labels}#{label_suffix} #{sum}),
        ~s(#{name}_count#{label_prefix}#{labels}#{label_suffix} #{count})
      ]
      |> Enum.intersperse(?\n)

    Enum.intersperse([samples, summary], ?\n)
  end

  defp format_standard({metric, series}, type) do
    name = format_name(metric.name)
    help = "# HELP #{name} #{escape_help(metric.description)}"
    type = "# TYPE #{name} #{type}"

    samples =
      Enum.map_intersperse(series, ?\n, fn {labels, value} ->
        has_lables? = length(labels) > 0

        if has_lables? do
          "#{name}{#{format_labels(labels)}} #{value}"
        else
          "#{name} #{value}"
        end
      end)

    Enum.intersperse([help, type, samples], ?\n)
  end

  defp format_labels(labels) do
    labels
    |> Enum.map(fn {k, v} -> ~s/#{k}="#{escape(v)}"/ end)
    |> Enum.sort()
    |> Enum.intersperse(",")
  end

  defp format_name(name) do
    name
    |> Enum.join("_")
    |> String.replace(~r/[^a-zA-Z0-9_]/, "")
    |> String.replace(~r/^[^a-zA-Z]+/, "")
  end

  defp escape(value) do
    value
    |> to_string()
    |> String.replace(~S("), ~S(\"))
    |> String.replace(~S(\\), ~S(\\\\))
    |> String.replace(~S(\n), ~S(\\n))
  end

  defp escape_help(value) do
    value
    |> to_string()
    |> String.replace(~S(\\), ~S(\\\\))
    |> String.replace(~S(\n), ~S(\\n))
  end

  defp prefix_sums(buckets), do: prefix_sums(buckets, [], 0)
  defp prefix_sums([], acc, sum), do: {Enum.reverse(acc), sum}

  defp prefix_sums([{bucket, count} | rest], acc, sum) do
    new_sum = sum + count
    new_bucket = {bucket, new_sum}
    prefix_sums(rest, [new_bucket | acc], new_sum)
  end
end
