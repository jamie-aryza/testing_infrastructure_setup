@{
    # S3 bucket where SQL Server ISOs are stored.
    # Update this name in both SqlIsoS3Uri entries below when the bucket changes.
    # Bucket is created manually (see README) — not managed by Terraform yet.
    IsoStagePath = 'C:\ProgramData\Amazon\HostPrep\sql-server.iso'

    Hosts = @(
        @{
            Name                = 'dev-live'
            TerraformOutputName = 'sql_live_public_ip'
            IniPath             = 'scripts/sql-install/ConfigurationFile.live.ini'
            SqlIsoS3Uri         = 's3://aryza-sql-server-install/sql2019-developer-x64.iso'   # s3://your-bucket/sql2019-developer-x64.iso
        }
        @{
            Name                = 'dev-test'
            TerraformOutputName = 'sql_test_public_ip'
            # PoC: using SQL 2019 because the SQL 2012 ISO is not readily available.
            # Long term: prod's "test" role runs SQL 2012 (reporting instance). When the 2012 ISO
            # is sourced, swap in scripts/sql-install/archive/ConfigurationFile.test-sql2012.ini
            # as ConfigurationFile.test.ini and update SqlIsoS3Uri to the 2012 ISO.
            IniPath             = 'scripts/sql-install/ConfigurationFile.test.ini'
            SqlIsoS3Uri         = 's3://aryza-sql-server-install/sql2019-developer-x64.iso'   # s3://your-bucket/sql2019-developer-x64.iso  (same ISO as dev-live for now)
        }
    )
}
