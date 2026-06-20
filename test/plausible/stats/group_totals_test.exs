defmodule Plausible.Stats.GroupTotalsTest do
  use Plausible.DataCase, async: true

  alias Plausible.Stats.GroupTotals

  @now ~N[2025-06-15 12:30:00]

  describe "compute/2" do
    test "returns zeros for an empty group without hitting the database" do
      assert GroupTotals.compute([], @now) == %{
               active_users: 0,
               visitors_30min: 0,
               pageviews_today: 0,
               pageviews_yesterday: 0
             }
    end

    test "computes the four summary metrics for a single site" do
      site = new_site()

      populate_stats(site, [
        # within 5 min -> active, 30min, today
        build(:pageview, user_id: 1, timestamp: ~N[2025-06-15 12:28:00]),
        # within 30 min (not 5 min) -> 30min, today
        build(:pageview, user_id: 2, timestamp: ~N[2025-06-15 12:10:00]),
        # earlier today -> today only
        build(:pageview, user_id: 3, timestamp: ~N[2025-06-15 03:00:00]),
        # custom event within 5 min -> counts as an active/30min visitor, NOT a pageview
        build(:event, name: "Signup", user_id: 9, timestamp: ~N[2025-06-15 12:29:00]),
        # yesterday
        build(:pageview, user_id: 4, timestamp: ~N[2025-06-14 09:00:00]),
        # two days ago -> counted nowhere
        build(:pageview, user_id: 5, timestamp: ~N[2025-06-13 09:00:00])
      ])

      assert GroupTotals.compute([site.id], @now) == %{
               active_users: 2,
               visitors_30min: 3,
               pageviews_today: 3,
               pageviews_yesterday: 1
             }
    end

    test "aggregates across every site in the group" do
      site1 = new_site()
      site2 = new_site()

      populate_stats(site1, [
        build(:pageview, user_id: 1, timestamp: ~N[2025-06-15 12:28:00])
      ])

      populate_stats(site2, [
        build(:pageview, user_id: 2, timestamp: ~N[2025-06-15 12:28:00])
      ])

      assert %{active_users: 2, visitors_30min: 2, pageviews_today: 2} =
               GroupTotals.compute([site1.id, site2.id], @now)
    end

    test "excludes engagement events from the unique visitor counts" do
      site = new_site()

      populate_stats(site, [
        build(:pageview, user_id: 1, timestamp: ~N[2025-06-15 12:28:00]),
        build(:engagement,
          user_id: 7,
          pathname: "/blog",
          timestamp: ~N[2025-06-15 12:28:30],
          scroll_depth: 20,
          engagement_time: 1000
        )
      ])

      assert %{active_users: 1, visitors_30min: 1} = GroupTotals.compute([site.id], @now)
    end
  end

  describe "for_domains/2" do
    test "splits sites into main/side by exact domain and sums them into total" do
      main = new_site(domain: "wikily.gg")
      side = new_site(domain: "some-side-wiki.com")

      populate_stats(main, [
        build(:pageview, user_id: 1, timestamp: ~N[2025-06-15 12:28:00])
      ])

      populate_stats(side, [
        build(:pageview, user_id: 2, timestamp: ~N[2025-06-15 12:29:00]),
        build(:pageview, user_id: 3, timestamp: ~N[2025-06-15 11:00:00])
      ])

      domains = %{main.id => "wikily.gg", side.id => "some-side-wiki.com"}

      assert %{
               main: %{active_users: 1, pageviews_today: 1},
               side: %{active_users: 1, pageviews_today: 2},
               total: %{active_users: 2, pageviews_today: 3}
             } = GroupTotals.for_domains(domains, @now)
    end

    test "treats a subdomain of a main domain as a side site (exact match only)" do
      side = new_site(domain: "docs.wikily.gg")

      populate_stats(side, [
        build(:pageview, user_id: 1, timestamp: ~N[2025-06-15 12:28:00])
      ])

      domains = %{side.id => "docs.wikily.gg"}

      assert %{
               main: %{active_users: 0},
               side: %{active_users: 1},
               total: %{active_users: 1}
             } = GroupTotals.for_domains(domains, @now)
    end
  end
end
