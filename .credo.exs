%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "src/", "test/", "web/", "apps/"],
        excluded: [
          ~r"/_build/",
          ~r"/deps/",
          ~r"/node_modules/",
          # Generated from priv/proto/gtfs-realtime.proto; not hand-written.
          ~r"/alerts/protobuf/"
        ]
      }
    }
  ]
}
