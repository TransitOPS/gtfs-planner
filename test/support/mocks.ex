# Define mocks for testing
Mox.defmock(GtfsPlanner.Gtfs.ValidatorMock, for: GtfsPlanner.Gtfs.ValidatorBehaviour)
Mox.defmock(GtfsPlanner.GeocodingMock, for: GtfsPlanner.Geocoding.Behaviour)

Mox.defmock(GtfsPlanner.Organizations.AdminReadAdapterMock,
  for: GtfsPlanner.Organizations.AdminReadAdapter
)

Mox.defmock(GtfsPlanner.Gtfs.CatalogReadAdapterMock,
  for: GtfsPlanner.Gtfs.CatalogReadAdapter
)

Mox.defmock(GtfsPlanner.Gtfs.ReviewedApplyTransactionMock,
  for: GtfsPlanner.Gtfs.ReviewedApplyTransaction
)
