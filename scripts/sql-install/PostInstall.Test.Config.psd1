# Post-install configuration for the Test SQL Server role (reporting / secondary).
# Generated/updated by Inventory-SqlServer.ps1 -Environment Test.
# Review TargetDatabase before running Invoke-PostInstall.ps1.
@{
    # Path to infrastructure-baseline/<server>/ produced by Inventory-SqlServer.ps1.
    # Updated automatically when Inventory-SqlServer.ps1 is run with -Environment Test.
    BaselinePath = 'infrastructure-baseline\local-test'

    # DBMail handling on dev/test.
    # NEVER sync from prod - prod sends to real recipients.
    # Disable         - set DBMail XPs = 0 (safest default)
    # RedirectToLocal - recreate accounts/profiles pointing at a local SMTP catcher (smtp4dev / MailHog)
    DbMailMode    = 'Disable'
    LocalSmtpHost = 'localhost'
    LocalSmtpPort = 25

    # Pipeline SQL login created on the test SQL Server.
    GhaDeployLoginName = 'gha_deploy'

    # Database to grant the pipeline login db_owner on. Leave empty to skip the grant.
    TargetDatabase = ''

    # Linked server: this host creates a linked server pointing at the other host in the same environment.
    # LinkedServerName:                  name of the linked server object created on THIS host.
    # LinkedServerLogin:                 SQL login created on THIS host for the remote host to authenticate with.
    #                                    Use the same name and password on both hosts for simplicity.
    # LinkedServerRemoteTerraformOutput: Terraform output key holding the remote host's IP.
    LinkedServerName                  = 'SQL-LIVE'
    LinkedServerLogin                 = 'ls_remote_query'
    LinkedServerRemoteTerraformOutput = 'sql_live_public_ip'
}
