defmodule Plausible.Stats.GroupTotals do
  @moduledoc """
  Aggregate "at a glance" totals for groups of sites, used by the sites index
  dashboard summary cards (Total / Main / Side).

  Each metric is computed with a single `site_id IN (...)` query against
  `events_v2`, so a group of N sites costs one ClickHouse scan per metric rather
  than N per-site queries.

  Day boundaries for "today" and "yesterday" pageviews are computed in UTC.
  Because Plausible's `user_id` is salted per site, the same person visiting two
  different sites is counted under two different ids - so unique visitor counts
  are additive across disjoint groups, which lets `total` be derived by summing
  `main` and `side`.
  """

  use Plausible.ClickhouseRepo
  use Plausible.Stats.SQL.Fragments

  @main_domains ["wikily.gg", "ark-unity.com", "nightingale-lab.com"]

  @type t() :: %{atom() => non_neg_integer()}
  @type grouped() :: %{main: t(), side: t(), total: t()}

  @zero %{active_users: 0, visitors_30min: 0, pageviews_today: 0, pageviews_yesterday: 0}

  @doc """
  The domains that make up the "Main" group. Everything else is "Side".
  """
  @spec main_domains() :: [String.t()]
  def main_domains, do: @main_domains

  @doc """
  Partitions a `%{site_id => domain}` map into Main / Side site id groups and
  returns totals for `main`, `side` and the combined `total`.
  """
  @spec for_domains(%{optional(pos_integer()) => String.t()}, NaiveDateTime.t()) :: grouped()
  def for_domains(domains_by_id, now \\ NaiveDateTime.utc_now()) do
    {main_ids, side_ids} = partition(domains_by_id)
    for_groups(main_ids, side_ids, now)
  end

  @doc """
  Partitions a `%{site_id => domain}` map into `{main_ids, side_ids}` by exact
  domain match against `main_domains/0`.
  """
  @spec partition(%{optional(pos_integer()) => String.t()}) :: {[pos_integer()], [pos_integer()]}
  def partition(domains_by_id) do
    {main_pairs, side_pairs} =
      Enum.split_with(domains_by_id, fn {_id, domain} -> domain in @main_domains end)

    {Enum.map(main_pairs, &elem(&1, 0)), Enum.map(side_pairs, &elem(&1, 0))}
  end

  @doc """
  Computes totals for the `main` and `side` site id groups and the combined
  `total` (the element-wise sum of the two).
  """
  @spec for_groups([pos_integer()], [pos_integer()], NaiveDateTime.t()) :: grouped()
  def for_groups(main_ids, side_ids, now \\ NaiveDateTime.utc_now()) do
    main = compute(main_ids, now)
    side = compute(side_ids, now)
    %{main: main, side: side, total: sum(main, side)}
  end

  @doc """
  Computes the four summary metrics for a single group of site ids.
  """
  @spec compute([pos_integer()], NaiveDateTime.t()) :: t()
  def compute(site_ids, now \\ NaiveDateTime.utc_now())

  def compute([], _now), do: @zero

  def compute(site_ids, now) when is_list(site_ids) do
    now = NaiveDateTime.truncate(now, :second)
    today_start = beginning_of_day(now)
    tomorrow_start = NaiveDateTime.add(today_start, 1, :day)
    yesterday_start = NaiveDateTime.add(today_start, -1, :day)

    %{
      active_users: unique_users_since(site_ids, NaiveDateTime.add(now, -5, :minute)),
      visitors_30min: unique_users_since(site_ids, NaiveDateTime.add(now, -30, :minute)),
      pageviews_today: pageviews_between(site_ids, today_start, tomorrow_start),
      pageviews_yesterday: pageviews_between(site_ids, yesterday_start, today_start)
    }
  end

  defp sum(main, side) do
    %{
      active_users: main.active_users + side.active_users,
      visitors_30min: main.visitors_30min + side.visitors_30min,
      pageviews_today: main.pageviews_today + side.pageviews_today,
      pageviews_yesterday: main.pageviews_yesterday + side.pageviews_yesterday
    }
  end

  defp unique_users_since(site_ids, first_datetime) do
    ClickhouseRepo.one(
      from e in "events_v2",
        where: fragment("? in ?", e.site_id, ^site_ids),
        where: e.timestamp >= ^first_datetime,
        where: e.name != "engagement",
        select: uniq(e.user_id)
    )
  end

  defp pageviews_between(site_ids, from_datetime, to_datetime) do
    ClickhouseRepo.one(
      from e in "events_v2",
        where: fragment("? in ?", e.site_id, ^site_ids),
        where: e.name == "pageview",
        where: e.timestamp >= ^from_datetime and e.timestamp < ^to_datetime,
        select: total()
    )
  end

  defp beginning_of_day(naive) do
    NaiveDateTime.new!(NaiveDateTime.to_date(naive), ~T[00:00:00])
  end
end
