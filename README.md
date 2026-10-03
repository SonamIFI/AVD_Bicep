# Code-only AVD deployment

This configuration targets Azure Public cloud, cloud-only Microsoft Entra member
accounts, Windows 11 24H2 AVD hosts, and Premium Azure Files for FSLogix.

## Prerequisites

- Current Azure CLI with Bicep installed (`az bicep install`) and PowerShell.
- Sign in with `az login` to the intended tenant.
- The operator needs subscription deployment permissions, permission to assign
  Azure roles, and permission to list storage keys for initial profile ACL setup.
- Entra permissions to create security groups, manage membership, update the
  storage application, and grant admin consent. Azure Owner alone is not enough.
- Conditional Access read permissions. Policy updates additionally require
  Conditional Access Administrator (or equivalent) and explicit approval.
- AVD-eligible user licensing and a current Windows 11 AVD image. Cloud-only SMB
  authentication needs 24H2 build 26100.8116 or later. VM configuration checks
  this requirement and fails deployment if the Marketplace image is too old.

## Deploy

### GitHub Actions

The repository includes `.github/workflows/deploy-avd.yml`. It runs only when
manually dispatched, compiles Bicep, tests FSLogix installer logic, signs in to
Azure using OIDC, and runs the full deployment script. The workflow uses the
protected GitHub Environment `avd-deploy`; configure required reviewers there
to gate deployments, since each run can create billable resources and restart
session hosts.

Configure these GitHub Environment variables for `avd-deploy`:

- `AZURE_CLIENT_ID`: Entra application/client ID configured for GitHub OIDC.
- `AZURE_TENANT_ID`: Entra tenant ID.
- `AZURE_SUBSCRIPTION_ID`: deployment subscription ID.

Add this GitHub Environment secret:

- `AVD_ADMIN_PASSWORD`: local session-host administrator password.

Configure a federated identity credential on the Entra application for this
repository and the `avd-deploy` GitHub Environment. Grant the identity the Azure
deployment/role-assignment permissions and Microsoft Graph application
permissions required by `deploy.ps1`, with admin consent. Do not create or store
a client secret for this workflow. Run **Actions > Deploy AVD > Run workflow**,
provide the cloud-only user object IDs, and leave the MFA exclusion option off
unless the exact policy IDs have already been reviewed and approved.

From the workspace root, supply the subscription ID and cloud-only user object
IDs. These IDs are not passwords or application client IDs.

```powershell
./Scripts/deploy.ps1 `
  -SubscriptionId '<subscription-guid>' `
  -UserObjectIds '<user-object-guid-1>', '<user-object-guid-2>'
```

Interactive runs securely prompt for the VM administrator password. The GitHub
workflow reads `AVD_ADMIN_PASSWORD` from the protected environment secret and
converts it to a SecureString in the running process. Never commit the password
or pass it as a plaintext command-line argument.

The script creates or reuses the named cloud-only access group, adds the supplied
users without removing existing members, and deploys infrastructure before VMs.
It configures the Azure Files application's admin consent, cloud-group SID tag,
and private-link identifiers, then deploys and registers the hosts. Registration
tokens are generated for one day and passed only to protected extension settings.

If an MFA policy applies to the storage app, the script stops before deploying
hosts. To approve an exclusion for that storage app only, rerun with the exact
policy IDs and both options:

```powershell
./Scripts/deploy.ps1 `
  -SubscriptionId '<subscription-guid>' `
  -UserObjectIds '<user-object-guid>' `
  -ExcludeStorageFromMfaPolicies `
  -MfaPolicyIds '<approved-policy-guid>'
```

No policy is disabled. Application-filter policies require separate review;
security defaults or other tenant authentication restrictions can also block
Kerberos and must be resolved by the tenant administrator. The script does not
weaken these settings automatically.

## Behavior and verification

- Azure Firewall Basic allows AVD service, Azure Monitor, agent, activation,
  certificate, Entra, FSLogix-download, Windows Update, diagnostics, telemetry,
  OneDrive, DNS-over-HTTPS and service-bus diagnostic traffic. Threat intelligence
  is set to `Alert`; Basic cannot enforce threat-intelligence deny mode.
- Basic doesn't support DNS proxy, custom DNS, or FQDN-based network rules. The
  VNet therefore keeps Azure-provided DNS, NTP isn't enabled by default, and
  direct RDP Shortpath is disabled by default. Relay Shortpath on UDP 3478 is
  allowed for the WindowsVirtualDesktop service tag. To enable NTP or direct
  Shortpath, pass tightly scoped IPs/CIDRs to `ntpServerIpAddresses` and
  `rdpShortpathDestinationCidrs` in a `.bicepparam` file or deployment override;
  don't use `0.0.0.0/0` for Shortpath. Azure platform DNS/IMDS/WireServer traffic
  must remain on Azure's platform path and isn't redirected through this firewall.
- Access is granted through group membership, desktop access, VM login, and SMB
  contributor roles. `maxAuthorizedUsers` is a planning label, not an enforced
  user cap; the script accepts up to ten supplied users per invocation.
- Start VM on Connect retains its power-on service role at the dedicated RG.
- The share has public network access disabled. Private DNS routes SMB directly
  within the VNet rather than through the internet firewall. Portal data browsing
  requires network access to the private endpoint; ARM share visibility does not.
- The first VM sets root ACLs using a protected storage key. Members can create
  profile folders but do not inherit access to other users' profile contents.
  The key is not a user authentication mechanism and is not stored in cmdkey.
- When FSLogix is missing, hosts download Microsoft's latest package from
  `https://aka.ms/fslogix_download`, verify the x64 installer's Microsoft signature,
  and install silently before applying FSLogix and Kerberos registry configuration.
  Existing installations are retained, not automatically upgraded. Installer logs
  remain under `C:\ProgramData\FSLogix\Deployment\install.log`; temporary downloads
  are removed. Download or installation failures fail the VM setup deployment.
- The deployment script restarts every deployed session-host VM after setup to
  activate drivers and Kerberos settings, including on redeployment. Schedule
  redeployments during a maintenance window to avoid interrupting active users.
  Direct Bicep deployment does not perform this restart. No existing local
  profiles are deleted automatically.
- Deployment verifies the share through ARM and prints AVD host health checks.
  Hosts may need additional startup time before becoming Available. A failed
  health gate does not delete resources or prove that the share is missing.
- Test a fresh authorized user sign-in and verify a new FSLogix container on
  `\\<storage-account>.file.core.windows.net\de-fslogix`. Infrastructure compilation
  cannot prove user authentication or profile attachment.

`parameters.bicepparam` reads `AVD_ADMIN_PASSWORD`, `AVD_USER_GROUP_OBJECT_ID`, and
`AVD_SERVICE_PRINCIPAL_OBJECT_ID`. The deployment script sets and restores these
process environment variables. VS Code may report missing-variable diagnostics
outside that process; they are intentional required inputs, not embedded secrets.

If a deleted Key Vault name remains soft-deleted with purge protection, Azure
can reject recreation. Recover the vault through an approved scripted recovery
workflow or use a new environment name; do not purge protected secrets to retry.

The Azure Portal FileServiceBlade extension failure cannot be repaired by Bicep.

## Local validation

```powershell
./Scripts/Test-FSLogixInstallation.ps1
az bicep build --file main.bicep
```

The installation tests use mocks; they do not download packages, install software,
change registry settings, or restart local or Azure machines.