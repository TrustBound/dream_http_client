//// Look inside the `dream_http_client_ref_mapping` ETS table, for the table
//// ownership regression tests.

/// True when the table exists.
@external(erlang, "ets_table_ownership_ffi", "table_exists")
pub fn exists() -> Bool

/// True when the table owner is not the calling process.
@external(erlang, "ets_table_ownership_ffi", "table_owner_is_not_self")
pub fn owner_is_not_self() -> Bool

/// True when the table owner is alive.
@external(erlang, "ets_table_ownership_ffi", "table_owner_is_alive")
pub fn owner_is_alive() -> Bool

/// Store a test mapping in the table.
@external(erlang, "ets_table_ownership_ffi", "store_test_mapping")
pub fn store_test_mapping() -> Nil

/// True when the test mapping is in the table.
@external(erlang, "ets_table_ownership_ffi", "lookup_test_mapping_exists")
pub fn test_mapping_exists() -> Bool

/// Remove the test mapping from the table.
@external(erlang, "ets_table_ownership_ffi", "clear_test_mappings")
pub fn clear_test_mappings() -> Nil
