// =============================================================================
// analytics-export
//
// Returns a provider's analytics for a date range as CSV.
//
// Authorisation model: this function deliberately does NOT use the service
// role. It forwards the caller's own JWT to PostgREST, so provider_analytics
// runs as that user and its own not_owner check does the gating. A stolen or
// spoofed provider_id therefore gets nothing.
// =============================================================================
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, jsonError, preflight } from "../_shared/cors.ts";

interface AnalyticsBundle {
  range: { start: string; end: string; timezone: string };
  totals: { total: number; completed: number; cancelled: number; active: number };
  current_queue_length: number;
  completion_rate: number | null;
  avg_time_to_complete_seconds: number;
  median_time_to_complete_seconds: number;
  over_time: Array<{ day: string; count: number }>;
  by_item: Array<{ item: string; count: number; quantity: number }>;
  busiest_hours: Array<{ hour: number; count: number }>;
}

function csvEscape(value: unknown): string {
  const s = value === null || value === undefined ? "" : String(value);
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

function toCsv(a: AnalyticsBundle): string {
  const rows: string[][] = [
    ["section", "key", "value"],
    ["range", "start", a.range.start],
    ["range", "end", a.range.end],
    ["range", "timezone", a.range.timezone],
    ["totals", "total", a.totals.total],
    ["totals", "completed", a.totals.completed],
    ["totals", "cancelled", a.totals.cancelled],
    ["totals", "active", a.totals.active],
    ["totals", "current_queue_length", a.current_queue_length],
    ["totals", "completion_rate", a.completion_rate ?? ""],
    ["totals", "avg_time_to_complete_seconds", a.avg_time_to_complete_seconds],
    ["totals", "median_time_to_complete_seconds", a.median_time_to_complete_seconds],
  ].map((r) => r.map(String));

  for (const p of a.over_time) rows.push(["over_time", p.day, String(p.count)]);
  for (const p of a.by_item) rows.push(["by_item", p.item, String(p.count)]);
  for (const p of a.busiest_hours) rows.push(["busiest_hours", String(p.hour), String(p.count)]);

  return rows.map((r) => r.map(csvEscape).join(",")).join("\n");
}

Deno.serve(async (req: Request) => {
  const pre = preflight(req);
  if (pre) return pre;

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return jsonError("unauthenticated", 401);

  let providerId: string | null = null;
  let rangeStart: string | null = null;
  let rangeEnd: string | null = null;

  try {
    if (req.method === "POST") {
      const body = await req.json();
      providerId = body.provider_id ?? null;
      rangeStart = body.range_start ?? null;
      rangeEnd = body.range_end ?? null;
    } else {
      const url = new URL(req.url);
      providerId = url.searchParams.get("provider_id");
      rangeStart = url.searchParams.get("range_start");
      rangeEnd = url.searchParams.get("range_end");
    }
  } catch {
    return jsonError("invalid_body", 400);
  }

  if (!providerId) return jsonError("provider_id_required", 400);

  // Caller's JWT, not the service role. The database enforces ownership.
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );

  const { data, error } = await supabase.rpc("provider_analytics", {
    p_provider_id: providerId,
    ...(rangeStart ? { p_range_start: rangeStart } : {}),
    ...(rangeEnd ? { p_range_end: rangeEnd } : {}),
  });

  if (error) {
    const code = error.message?.trim();
    const status = code === "not_owner" ? 403 : code === "unauthenticated" ? 401 : 400;
    return jsonError(code || "analytics_failed", status);
  }

  const csv = toCsv(data as AnalyticsBundle);
  const stamp = new Date().toISOString().slice(0, 10);

  return new Response(csv, {
    headers: {
      ...corsHeaders,
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": `attachment; filename="teregna-analytics-${stamp}.csv"`,
    },
  });
});
