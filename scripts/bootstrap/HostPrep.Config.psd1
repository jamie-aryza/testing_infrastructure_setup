@{
    TimeZone = 'GMT Standard Time'
    EnableRdp = $false
    BootstrapRoot = 'C:\ProgramData\Amazon\HostPrep'
    DiskMap = @(
        @{
            Purpose         = 'SQL data'
            ExpectedSizeGiB = 20
            DriveLetter     = 'F'
            Label           = 'SQLDATA'
        }
        @{
            Purpose         = 'SQL log'
            ExpectedSizeGiB = 10
            DriveLetter     = 'G'
            Label           = 'SQLLOG'
        }
    )
    Hosts = @(
        @{
            Name                 = 'dev-live'
            Role                 = 'live'
            WindowsServerVersion = '2022'
            TerraformOutputName  = 'sql_live_public_ip'
        }
        @{
            Name                 = 'dev-test'
            Role                 = 'test'
            WindowsServerVersion = '2016'
            TerraformOutputName  = 'sql_test_public_ip'
        }
    )
}
