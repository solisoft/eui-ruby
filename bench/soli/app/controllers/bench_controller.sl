# A table of ROWS keyed rows, a sort that reverses them, and a tick that
# changes one number.
#
# Everything is a raw node hash rather than a builder, because the Ruby
# side is written the same way: the point is to compare what it costs to
# turn the same tree into the same bytes.

ROWS = 500

def bench_cells(i)
  [
    "FA-" + i.to_s,
    "Client " + (i % 37).to_s + " SARL",
    i % 3 == 0 ? "Paid" : "Open",
    (100 + i * 37).to_s + " EUR"
  ]
end

def bench_row(i, widths)
  values = bench_cells(i)
  cells = range(0, 4).map(fn(c) { {
    "k": "text",
    "t": values[c],
    "s": {"width": widths[c], "size": 1, "fg": "text.default"}
  } })
  {
    "k": "box",
    "key": "r" + i.to_s,
    "s": {
      "display": "row", "gap": 4, "pad": [1, 3, 1, 3],
      "border": [0, 0, 1, 0], "border_color": "border.subtle"
    },
    "c": cells
  }
end

def bench(event_data)
  state = event_data["state"] ?? {}
  event = event_data["event"]
  return {"order": "asc", "ticks": 0} if event == "connect"
  order = state["order"] ?? "asc"
  ticks = state["ticks"] ?? 0
  return {"order": order == "asc" ? "desc" : "asc", "ticks": ticks} if event == "sort"
  return {"order": order, "ticks": ticks + 1} if event == "tick"
  {"order": order, "ticks": ticks}
end

def bench_view(raw_state)
  state = raw_state ?? {}
  order = state["order"] ?? "asc"
  ticks = state["ticks"] ?? 0
  widths = [90, 160, 90, 90]
  ids = range(0, ROWS)
  ids = ids.reverse() if order == "desc"
  rows = ids.map(fn(i) { bench_row(i, widths) })
  {
    "k": "box",
    "s": {"display": "column", "pad": 6, "gap": 3, "bg": "surface.base", "width": "100%", "height": "100%"},
    "c": [
      {
        "k": "box",
        "s": {"display": "row", "gap": 3, "align": "center"},
        "c": [
          {"k": "text", "t": "Invoices", "s": {"size": 5, "weight": "bold"}},
          {"k": "text", "t": ticks.to_s, "s": {"size": 2, "fg": "text.muted", "font": "mono"}},
          {"k": "spacer", "s": {"grow": 1}},
          {
            "k": "box",
            "s": {"bg": "surface.raised", "radius": 2, "pad": [2, 4], "cursor": "pointer"},
            "on": {"click": "sort"},
            "c": [{"k": "text", "t": order == "asc" ? "Sort down" : "Sort up", "s": {"weight": "medium"}}]
          },
          {
            "k": "box",
            "s": {"bg": "accent.base", "radius": 2, "pad": [2, 4], "cursor": "pointer"},
            "on": {"click": "tick"},
            "c": [{"k": "text", "t": "Tick", "s": {"fg": "accent.on", "weight": "medium"}}]
          }
        ]
      },
      {"k": "scroll", "s": {"grow": 1, "width": "100%"}, "c": [
        {"k": "box", "s": {"display": "column"}, "c": rows}
      ]}
    ]
  }
end
