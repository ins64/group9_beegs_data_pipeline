output "warehouses" {
  value = [snowflake_warehouse.pipeline.name, snowflake_warehouse.bi.name]
}
output "schemas" {
  value = [for s in snowflake_schema.s : s.fully_qualified_name]
}
output "roles" {
  value = [snowflake_account_role.pipeline.name, snowflake_account_role.purchasing.name, snowflake_account_role.analyst.name]
}
