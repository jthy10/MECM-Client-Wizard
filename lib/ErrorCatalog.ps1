<#
    ===========================================================================
     MECM Client Wizard  --  lib\ErrorCatalog.ps1
    ---------------------------------------------------------------------------
     Translation tables that turn the two things a CCM log actually gives you
     into something an operator can act on:

       1. $MDErrorCatalog   - numeric error codes  ->  plain English + a fix
       2. $MDPatternCatalog - message text patterns for the failures that never
                              carry a code (the "Failed to send message" class)

     Codes are keyed on the canonical 0xXXXXXXXX form produced by
     ConvertTo-MDHexError, because the same failure is written as a signed
     decimal by one component and as hex by the next.

     Adding an entry is deliberately trivial - that is the whole point of
     keeping this in its own file. Contributions welcome.
    ===========================================================================
#>

# ---------------------------------------------------------------------------
# Numeric error codes.
#   Name   - the symbolic constant, so the code can be searched for elsewhere
#   Means  - what actually went wrong, in operator language
#   Fix    - the first thing to try
#   Area   - groups the code for the summary (WMI / Network / Content / ...)
# ---------------------------------------------------------------------------
$script:MDErrorCatalog = @{

    # -- WMI -----------------------------------------------------------------
    '0x80041001' = @{ Name = 'WBEM_E_FAILED';                Area = 'WMI';      Means = 'Generic WMI failure. Usually a provider that failed to load, or a corrupt repository.'; Fix = 'Run: mecmdoctor repair -Level Standard (verifies and salvages the WMI repository).' }
    '0x80041002' = @{ Name = 'WBEM_E_NOT_FOUND';             Area = 'WMI';      Means = 'The requested WMI class or instance does not exist. For root\ccm this usually means the client MOFs never compiled.'; Fix = 'Repair the client (mecmdoctor repair -Level Standard). If it recurs, reinstall the client.' }
    '0x80041003' = @{ Name = 'WBEM_E_ACCESS_DENIED';         Area = 'WMI';      Means = 'The caller lacks rights on that WMI namespace.'; Fix = 'Run elevated. If it persists, WMI namespace security has been altered - check the DCOM/WMI ACLs applied by GPO.' }
    '0x80041010' = @{ Name = 'WBEM_E_INVALID_CLASS';         Area = 'WMI';      Means = 'The class is missing from the repository - a partially compiled or damaged namespace.'; Fix = 'Salvage the repository, then repair the client so its MOFs recompile.' }
    '0x8004100E' = @{ Name = 'WBEM_E_INVALID_NAMESPACE';     Area = 'WMI';      Means = 'The namespace does not exist. root\ccm missing means the client is not installed or its WMI namespace was destroyed.'; Fix = 'Reinstall the client (mecmdoctor reinstall).' }
    '0x80041014' = @{ Name = 'WBEM_E_INITIALIZATION_FAILURE';Area = 'WMI';      Means = 'A WMI provider could not initialise - classic symptom of a corrupt repository.'; Fix = 'Salvage the repository; reset it only if salvage fails.' }
    '0x80041017' = @{ Name = 'WBEM_E_INVALID_QUERY';         Area = 'WMI';      Means = 'Malformed WQL. Almost always a script problem rather than a client problem.'; Fix = 'No client action needed.' }
    '0x8004101D' = @{ Name = 'WBEM_E_UNEXPECTED';            Area = 'WMI';      Means = 'Internal WMI error, frequently seen when the repository is mid-corruption.'; Fix = 'Salvage the WMI repository and restart Winmgmt.' }
    '0x80041033' = @{ Name = 'WBEM_E_SHUTTING_DOWN';         Area = 'WMI';      Means = 'WMI is shutting down or restarting; the query arrived at the wrong moment.'; Fix = 'Retry. If constant, Winmgmt is crash-looping - check the Application event log for wmiprvse faults.' }
    '0x80041032' = @{ Name = 'WBEM_E_CALL_CANCELLED';        Area = 'WMI';      Means = 'The caller abandoned a WMI query before it finished. Common background noise; only meaningful if a client query is the one being cancelled.'; Fix = 'No action unless client queries are affected, in which case the provider is too slow - salvage the repository.' }
    '0x80041006' = @{ Name = 'WBEM_E_OUT_OF_MEMORY';         Area = 'WMI';      Means = 'WMI ran out of memory servicing the request, usually a provider leak rather than real exhaustion.'; Fix = 'Restart Winmgmt, then reboot if it recurs.' }
    '0x80041008' = @{ Name = 'WBEM_E_INVALID_PARAMETER';     Area = 'WMI';      Means = 'A WMI method was called with a bad parameter.'; Fix = 'Script-side problem, not a client fault.' }
    '0x8004106C' = @{ Name = 'WBEM_E_QUOTA_VIOLATION';       Area = 'WMI';      Means = 'A WMI provider quota was exceeded - typically memory per provider host.'; Fix = 'Identify the provider from WMI-Activity/Operational; restart Winmgmt as an interim fix.' }

    # -- Generic Win32 -------------------------------------------------------
    '0x80070002' = @{ Name = 'ERROR_FILE_NOT_FOUND';         Area = 'General';  Means = 'A required file is missing. In CAS/DTS logs this means content was expected in the cache and is not there.'; Fix = 'Clear the CCM cache and re-evaluate the deployment.' }
    '0x80070003' = @{ Name = 'ERROR_PATH_NOT_FOUND';         Area = 'General';  Means = 'A required folder is missing - often the CCM cache directory or a package source path.'; Fix = 'Verify the cache location exists and is writable; recreate it by clearing the cache.' }
    '0x80070005' = @{ Name = 'ERROR_ACCESS_DENIED';          Area = 'General';  Means = 'Access denied. Either the process is not elevated, or NTFS/registry/WMI permissions were changed by GPO.'; Fix = 'Run elevated. If already elevated, look for a security-baseline GPO restricting SYSTEM or the CCM folders.' }
    '0x80070057' = @{ Name = 'E_INVALIDARG';                 Area = 'General';  Means = 'Invalid parameter passed to an API - typically a malformed policy or a bad command line.'; Fix = 'Reset client policy so the malformed policy body is re-downloaded.' }
    '0x8007000E' = @{ Name = 'E_OUTOFMEMORY';                Area = 'General';  Means = 'Out of memory. Under CcmExec this is usually a runaway provider rather than genuine RAM exhaustion.'; Fix = 'Restart the SMS Agent Host; if it recurs, restart the machine.' }
    '0x8007000D' = @{ Name = 'ERROR_INVALID_DATA';           Area = 'Updates';  Means = 'Data is corrupt. On the update path this is almost always a damaged Windows Update datastore.'; Fix = 'Reset Windows Update components (mecmdoctor repair -Level Standard).' }
    '0x80070422' = @{ Name = 'ERROR_SERVICE_DISABLED';       Area = 'Services'; Means = 'A required service is disabled - usually Windows Update (wuauserv) turned off by GPO or a "debloat" script.'; Fix = 'Set wuauserv to Manual and start it. Check GPO is not re-disabling it.' }
    '0x80070490' = @{ Name = 'ERROR_NOT_FOUND';              Area = 'Updates';  Means = 'Component store lookup failed - CBS servicing stack corruption.'; Fix = 'Run: DISM /Online /Cleanup-Image /RestoreHealth  then  sfc /scannow.' }
    '0x80070643' = @{ Name = 'ERROR_INSTALL_FAILURE';        Area = 'Software'; Means = 'Generic MSI install failure. The real reason is in the MSI log, not here.'; Fix = 'Check AppEnforce.log for the MSI log path, then read that log for the failing action.' }
    '0x80070641' = @{ Name = 'ERROR_INSTALL_SERVICE_FAILURE';Area = 'Software'; Means = 'The Windows Installer service is unavailable.'; Fix = 'Start the msiserver service and re-run the deployment.' }
    '0x80070652' = @{ Name = 'ERROR_INSTALL_ALREADY_RUNNING';Area = 'Software'; Means = 'Another installation is already in progress.'; Fix = 'Wait for the other install to finish, or reboot to clear a stuck installer.' }
    '0x80004005' = @{ Name = 'E_FAIL';                       Area = 'General';  Means = 'Unspecified error. Meaningless on its own - the useful detail is in the surrounding log lines.'; Fix = 'Read the 10 lines above this entry in the same log for the real cause.' }
    '0x80072F8F' = @{ Name = 'WININET_E_SECURE_FAILURE';     Area = 'Network';  Means = 'TLS negotiation failed. Overwhelmingly the machine clock is wrong, or a required root CA is missing.'; Fix = 'Check system time against a domain controller (w32tm /resync) and verify the CA chain.' }

    # -- Network / MP communication -----------------------------------------
    '0x80072EE2' = @{ Name = 'ERROR_INTERNET_TIMEOUT';       Area = 'Network';  Means = 'The HTTP request to the management point timed out.'; Fix = 'Confirm the MP is reachable on 80/443 and that no proxy or firewall is silently dropping the traffic.' }
    '0x80072EE7' = @{ Name = 'ERROR_INTERNET_NAME_NOT_RESOLVED'; Area = 'Network'; Means = 'The management point name could not be resolved by DNS.'; Fix = 'Test with nslookup. Flush DNS, verify the client is on a network that can see internal DNS.' }
    '0x80072EFD' = @{ Name = 'ERROR_INTERNET_CANNOT_CONNECT';Area = 'Network';  Means = 'TCP connection to the MP was refused or blocked.'; Fix = 'Test-NetConnection <MP> -Port 80/443. Check host firewall and network segmentation.' }
    '0x80072EFE' = @{ Name = 'ERROR_INTERNET_CONNECTION_ABORTED'; Area = 'Network'; Means = 'The connection dropped mid-request - flaky link, or an inspecting proxy terminating the session.'; Fix = 'Exclude MP traffic from TLS inspection; check for VPN instability.' }
    '0x80072F0C' = @{ Name = 'ERROR_INTERNET_CLIENT_AUTH_CERT_NEEDED'; Area = 'Certificates'; Means = 'The MP requires a client authentication certificate and the client has none it can use.'; Fix = 'Verify PKI cert enrolment and that the cert is in the SMS store with a usable private key.' }
    '0x80072F06' = @{ Name = 'ERROR_INTERNET_SEC_CERT_CN_INVALID'; Area = 'Certificates'; Means = 'The server certificate name does not match the MP name the client is using.'; Fix = 'Check the MP FQDN in the site configuration matches the SAN on the MP certificate.' }
    '0x80072F05' = @{ Name = 'ERROR_INTERNET_SEC_CERT_DATE_INVALID'; Area = 'Certificates'; Means = 'The server certificate is expired or not yet valid - or the client clock is wrong.'; Fix = 'Check both the MP certificate validity and the client system time.' }
    '0x80190190' = @{ Name = 'BG_E_HTTP_ERROR_400';          Area = 'Content';  Means = 'HTTP 400 from the distribution point - malformed request, often a bad content path.'; Fix = 'Redistribute the content and re-evaluate the deployment.' }
    '0x80190191' = @{ Name = 'BG_E_HTTP_ERROR_401';          Area = 'Content';  Means = 'HTTP 401 unauthorized from the DP - the client could not authenticate for content.'; Fix = 'For HTTP DPs check anonymous access / network access account; for e-HTTP check the client token in ClientAuth.log.' }
    '0x80190193' = @{ Name = 'BG_E_HTTP_ERROR_403';          Area = 'Content';  Means = 'HTTP 403 forbidden - the DP refused the request, often boundary/DP access rules or IIS request filtering.'; Fix = 'Check IIS request filtering on the DP (double escaping must be allowed) and the client boundary group.' }
    '0x80190194' = @{ Name = 'BG_E_HTTP_ERROR_404';          Area = 'Content';  Means = 'HTTP 404 - the content is genuinely not on that distribution point.'; Fix = 'Confirm the package is distributed and shows Success on that DP, then redistribute.' }
    '0x801901F4' = @{ Name = 'BG_E_HTTP_ERROR_500';          Area = 'Content';  Means = 'HTTP 500 from the DP - server-side IIS or WebDAV failure.'; Fix = 'Check the DP IIS logs and application event log; verify WebDAV configuration.' }
    '0x801901F7' = @{ Name = 'BG_E_HTTP_ERROR_503';          Area = 'Content';  Means = 'HTTP 503 - the DP or MP is overloaded or its app pool is stopped.'; Fix = 'Check the IIS application pool state on the site server / DP.' }
    '0x80200010' = @{ Name = 'BG_E_DESTINATION_LOCKED';      Area = 'Content';  Means = 'BITS could not write to the destination - the cache folder is locked or on a full volume.'; Fix = 'Free disk space and clear the CCM cache.' }
    '0x80200013' = @{ Name = 'BG_E_INSUFFICIENT_RANGE_SUPPORT'; Area = 'Content'; Means = 'BITS range requests were rejected, usually by a proxy that does not honour partial content.'; Fix = 'Exclude DP traffic from the proxy, or enable range request support on it.' }
    '0x80200014' = @{ Name = 'BG_E_MISSING_FILE_SIZE';       Area = 'Content';  Means = 'The server did not return a content length - a proxy or WAF is rewriting the response.'; Fix = 'Bypass the intercepting proxy for DP traffic.' }

    # -- Certificates / registration ----------------------------------------
    '0x80090016' = @{ Name = 'NTE_BAD_KEYSET';               Area = 'Certificates'; Means = 'The private key for the client certificate is missing or unreadable by SYSTEM.'; Fix = 'Re-register the client (mecmdoctor repair -Level Standard) so it regenerates its self-signed cert.' }
    '0x8009000B' = @{ Name = 'NTE_BAD_KEY_STATE';            Area = 'Certificates'; Means = 'The key exists but is not usable in its current state - damaged MachineKeys ACLs are the usual cause.'; Fix = 'Check permissions on C:\ProgramData\Microsoft\Crypto\RSA\MachineKeys, then re-register.' }
    '0x80092004' = @{ Name = 'CRYPT_E_NOT_FOUND';            Area = 'Certificates'; Means = 'A required certificate could not be found in the store.'; Fix = 'Check the SMS certificate store; re-register the client to reissue the self-signed certificate.' }
    '0x800B0109' = @{ Name = 'CERT_E_UNTRUSTEDROOT';         Area = 'Certificates'; Means = 'The certificate chains to a root the client does not trust.'; Fix = 'Ensure the issuing CA root is in Trusted Root Certification Authorities on the client.' }
    '0x800B0101' = @{ Name = 'CERT_E_EXPIRED';               Area = 'Certificates'; Means = 'The certificate has expired (or the clock is wrong and it looks expired).'; Fix = 'Renew the certificate and verify system time.' }

    # -- Software Updates / WUA ---------------------------------------------
    '0x8024000B' = @{ Name = 'WU_E_CALL_CANCELLED';          Area = 'Updates';  Means = 'The update operation was cancelled - commonly a maintenance window closing mid-install.'; Fix = 'Normal if the service window ended. If constant, widen the maintenance window.' }
    '0x8024000E' = @{ Name = 'WU_E_XML_INVALID';             Area = 'Updates';  Means = 'The update agent received malformed XML - damaged update metadata.'; Fix = 'Reset Windows Update components and force a rescan.' }
    '0x8024001E' = @{ Name = 'WU_E_SERVICE_STOP';            Area = 'Updates';  Means = 'The operation aborted because the service or system was shutting down.'; Fix = 'Retry the scan/install after a clean boot.' }
    '0x80240022' = @{ Name = 'WU_E_ALL_UPDATES_FAILED';      Area = 'Updates';  Means = 'Every update in the batch failed. One bad update usually poisons the whole job.'; Fix = 'Read WUAHandler.log / UpdatesHandler.log to find the first failing update and exclude it.' }
    '0x80240438' = @{ Name = 'WU_E_PT_NO_MANAGED_RECOVER';   Area = 'Updates';  Means = 'The update agent could not reach any update service.'; Fix = 'Confirm the WSUS/MECM update point is reachable and that WSUS policy is not fighting MECM.' }
    '0x80244007' = @{ Name = 'WU_E_PT_SOAPCLIENT_SOAPFAULT'; Area = 'Updates';  Means = 'SOAP fault talking to WSUS - very often a duplicate or invalid SusClientId.'; Fix = 'Reset Windows Update components; this clears SusClientId so the client re-registers with WSUS.' }
    '0x80244010' = @{ Name = 'WU_E_PT_EXCEEDED_MAX_SERVER_TRIPS'; Area = 'Updates'; Means = 'The scan exceeded the maximum number of round trips to WSUS - the scan is simply too large.'; Fix = 'Decline superseded/expired updates on the update point and re-run the scan. Often succeeds on a second attempt.' }
    '0x80244022' = @{ Name = 'WU_E_PT_HTTP_STATUS_SERVICE_UNAVAIL'; Area = 'Updates'; Means = 'HTTP 503 from WSUS - the WsusPool application pool is stopped or has hit its private memory limit.'; Fix = 'Server-side: raise the WsusPool private memory limit and restart the pool.' }
    '0x8024401C' = @{ Name = 'WU_E_PT_HTTP_STATUS_REQUEST_TIMEOUT'; Area = 'Updates'; Means = 'HTTP 408 - WSUS did not respond in time, usually because it is overloaded.'; Fix = 'Retry later; server-side, run WSUS cleanup and reindex the SUSDB.' }
    '0x8024402C' = @{ Name = 'WU_E_PT_WINHTTP_NAME_NOT_RESOLVED'; Area = 'Updates'; Means = 'The WSUS/update point name did not resolve, or a stale WinHTTP proxy is being used.'; Fix = 'Check netsh winhttp show proxy and the WUServer registry value.' }
    '0x8024402F' = @{ Name = 'WU_E_PT_ECP_SUCCEEDED_WITH_ERRORS'; Area = 'Updates'; Means = 'External cab processing completed with errors - some update metadata was rejected.'; Fix = 'Usually transient. Force a rescan; if it persists, reset Windows Update components.' }
    '0x80248007' = @{ Name = 'WU_E_DS_NODATA';               Area = 'Updates';  Means = 'The Windows Update datastore has no record of the requested item - the datastore is missing or corrupt.'; Fix = 'Reset Windows Update components (renames SoftwareDistribution).' }
    '0x80248014' = @{ Name = 'WU_E_DS_UNKNOWNSERVICE';       Area = 'Updates';  Means = 'The update service ID is unknown to the datastore - MECM/WSUS service registration is broken.'; Fix = 'Reset Windows Update components and let the client re-register its update service.' }
    '0x800F0922' = @{ Name = 'CBS_E_INSTALLERS_FAILED';      Area = 'Updates';  Means = 'A servicing operation failed - most often too little free space in the System Reserved partition, or a failed .NET update.'; Fix = 'Check free space on the system and System Reserved volumes; review CBS.log.' }
    '0x800F081F' = @{ Name = 'CBS_E_SOURCE_MISSING';         Area = 'Updates';  Means = 'Servicing needed payload files that are not present.'; Fix = 'Run DISM /Online /Cleanup-Image /RestoreHealth with a valid source.' }
    '0x80073712' = @{ Name = 'ERROR_SXS_COMPONENT_STORE_CORRUPT'; Area = 'Updates'; Means = 'The component store is corrupt; no update will install until it is repaired.'; Fix = 'DISM /Online /Cleanup-Image /RestoreHealth, then sfc /scannow, then reboot.' }

    # -- MECM-specific (0x87Dxxxxx) -----------------------------------------
    '0x87D00213' = @{ Name = 'CCM_E_DTS_JOB_FAILED';         Area = 'Content';  Means = 'The data transfer job failed - the client could not pull content from any DP.'; Fix = 'Check DataTransferService.log for the HTTP status; verify content is distributed and boundaries are correct.' }
    '0x87D00215' = @{ Name = 'CCM_E_NO_CONTENT_LOCATIONS';   Area = 'Content';  Means = 'No distribution point could be found for this content. The client is in no boundary group that has a DP with this package.'; Fix = 'Check the client boundary/boundary group membership and that the package is distributed to a DP in that group.' }
    '0x87D00269' = @{ Name = 'CCM_E_NO_CONTENT_FOUND';       Area = 'Content';  Means = 'Content location request returned nothing.'; Fix = 'Redistribute the content, then re-evaluate. Confirm LocationServices.log is getting a valid MP list.' }
    '0x87D0027E' = @{ Name = 'CCM_E_ADDITIONAL_DOWNLOAD_REQUIRED'; Area = 'Updates'; Means = 'The update needs extra payload that is not in the deployment package.'; Fix = 'Download the missing update content into the deployment package on the site server.' }
    '0x87D00314' = @{ Name = 'CCM_E_CACHE_TOO_SMALL';        Area = 'Content';  Means = 'The content is larger than the configured CCM cache.'; Fix = 'Increase the client cache size, or clear it to reclaim space.' }
    '0x87D00320' = @{ Name = 'CCM_E_CACHESPACE_EXHAUSTED';   Area = 'Content';  Means = 'The cache is full of content that cannot be evicted (still referenced or pinned).'; Fix = 'Clear the CCM cache (mecmdoctor repair -Level Safe).' }
    '0x87D00664' = @{ Name = 'CCM_E_HASH_MISMATCH';          Area = 'Content';  Means = 'Downloaded content failed hash verification - corrupt on the DP, or mangled in transit by a proxy.'; Fix = 'Redistribute the content on the DP and clear the client cache. Exclude DP traffic from WAN optimisers.' }
    '0x87D00692' = @{ Name = 'CCM_E_GROUP_POLICY_CONFLICT';  Area = 'Updates';  Means = 'A Group Policy WSUS setting is overriding the MECM software update point. This is the classic "updates never install" cause.'; Fix = 'Remove the WUServer/UseWUServer GPO settings, or set the MECM client to allow GPO co-existence. Then reset WU components.' }
    '0x87D00693' = @{ Name = 'CCM_E_WSUS_SERVER_CHANGED';    Area = 'Updates';  Means = 'The WSUS server the client points at changed unexpectedly, invalidating the scan.'; Fix = 'Force a machine policy retrieval and a software update scan.' }
    '0x87D0070C' = @{ Name = 'CCM_E_SERVICE_WINDOW';         Area = 'Updates';  Means = 'The install could not run because no maintenance window was open.'; Fix = 'Expected outside a service window. Widen the window or deploy outside business hours.' }
    '0x87D01106' = @{ Name = 'CCM_E_APP_ENFORCEMENT_FAILED'; Area = 'Software'; Means = 'Application enforcement failed. The installer itself returned a failure.'; Fix = 'Read AppEnforce.log for the exact command line and its exit code.' }
    '0x87D20417' = @{ Name = 'CCM_E_CI_DOCUMENT_DOWNLOAD';   Area = 'Policy';   Means = 'The client could not download the configuration item documents referenced by policy.'; Fix = 'Reset client policy so the CI documents are requested again; verify MP connectivity.' }
    '0x87D00227' = @{ Name = 'CCM_E_DOWNLOAD_TIMEOUT';       Area = 'Content';  Means = 'The download exceeded the allowed time - slow link, or BITS throttled to near zero.'; Fix = 'Check BITS throttling policy and the client BITS jobs.' }
    '0x87D00631' = @{ Name = 'CCM_E_UPDATE_UNAPPROVED';      Area = 'Updates';  Means = 'The update is not approved/deployed to this client.'; Fix = 'Confirm the deployment targets a collection this device is in, then retrieve machine policy.' }
}


# ---------------------------------------------------------------------------
# Message patterns.
# Some of the most useful CCM log lines carry no error code at all. These are
# matched against the raw message text, in order, and the first hit wins.
#
#   Match  - regex tested against the message (case-insensitive)
#   Log    - restrict the pattern to one log file; $null means "any log"
# ---------------------------------------------------------------------------
$script:MDPatternCatalog = @(
    @{ Match = 'Failed to (send|get) .*(management point|MP)'; Log = $null; Area = 'Registration';
       Means = 'The client cannot talk to its management point at all.';
       Fix   = 'Confirm the MP name resolves and answers on 80/443, then check certificates in ClientAuth.log / CcmMessaging.log.' }

    @{ Match = 'Raising event:.*CcmHttp_Status.*(401|403)'; Log = $null; Area = 'Registration';
       Means = 'The MP rejected the client HTTP request as unauthenticated or forbidden.';
       Fix   = 'For e-HTTP sites check the client token; for PKI check the client authentication certificate.' }

    @{ Match = 'Failed to submit registration request'; Log = $null; Area = 'Registration';
       Means = 'Client registration never completed, so the client has no valid identity with the site.';
       Fix   = 'Re-register the client: mecmdoctor repair -Level Standard' }

    @{ Match = 'Client is not registered|Registration is not complete|Unable to (find|retrieve) the client (GUID|certificate)'; Log = $null; Area = 'Registration';
       Means = 'The client has no completed registration with the site.';
       Fix   = 'Re-register the client (drops SMSCFG.INI and the SMS certificates, then restarts CcmExec).' }

    @{ Match = 'Failed to (find|get) MP location|No (MP|management point) found|LSGetMPLocations? failed'; Log = $null; Area = 'Registration';
       Means = 'Management point lookup failed - the client does not know where to send anything.';
       Fix   = 'Check boundary group configuration and AD site assignment; force a machine policy retrieval.' }

    @{ Match = 'Failed to (open|read) WMI|Failed to connect to.*root\\ccm|GetNamedSecurityInfo.*failed'; Log = $null; Area = 'WMI';
       Means = 'The client could not use its own WMI namespace.';
       Fix   = 'Repair WMI: mecmdoctor repair -Level Standard' }

    @{ Match = 'Policy is corrupt|Failed to (compile|apply) polic|PolicyAgent.*failed to (evaluate|process)'; Log = $null; Area = 'Policy';
       Means = 'The client received policy it could not process.';
       Fix   = 'Reset client policy so the whole policy body is purged and re-downloaded.' }

    @{ Match = 'No update source found|Scan failed with error|OnSearchComplete - Failed'; Log = $null; Area = 'Updates';
       Means = 'The software update scan failed, so the client has no idea what it is missing.';
       Fix   = 'Reset Windows Update components, then force a scan: mecmdoctor repair -Level Standard' }

    @{ Match = 'Group policy settings were overwritten by a higher authority'; Log = $null; Area = 'Updates';
       Means = 'A WSUS Group Policy is overriding the MECM software update point.';
       Fix   = 'Remove the conflicting WUServer/UseWUServer GPO settings - MECM manages this itself.' }

    @{ Match = 'DownloadFiles failed|Failed to download content|Content download failed'; Log = $null; Area = 'Content';
       Means = 'Content download failed outright.';
       Fix   = 'Check the accompanying error code, clear the CCM cache, and confirm the content is on a DP in the client boundary group.' }

    @{ Match = 'The system cannot find the (file|path) specified'; Log = $null; Area = 'General';
       Means = 'A file or folder the client expected is gone.';
       Fix   = 'Usually a damaged cache or a partially removed client - clear the cache, then repair the client.' }

    @{ Match = 'Reboot is (required|pending)|RebootCoordinator.*pending'; Log = $null; Area = 'Reboot';
       Means = 'The client is blocked behind a pending reboot.';
       Fix   = 'Reboot the machine. Nothing else on the update path will complete until you do.' }

    @{ Match = 'CcmEval.*(failed|Fail)'; Log = 'CcmEval.log'; Area = 'Health';
       Means = 'Microsoft client health evaluation reported a failed check.';
       Fix   = 'Review CcmEvalReport.xml for the failing item; mecmdoctor surfaces this under CLIENT HEALTH.' }
)


function Resolve-MDError {
<#
    .SYNOPSIS
        Looks up one error code and returns its catalogue entry, or a generic
        stub when we have never seen it before.
    .PARAMETER Code
        Any representation: 0x8004100E, 2147749902, -2147217394, ...
#>
    param([Parameter(Mandatory)] $Code)

    $hex = ConvertTo-MDHexError $Code
    if (-not $hex) { return $null }

    # Zero is success. Log lines such as "returned 0" would otherwise be
    # reported as an uncatalogued error on every single run.
    if ($hex -eq '0x00000000') { return $null }

    if ($script:MDErrorCatalog.ContainsKey($hex)) {
        $e = $script:MDErrorCatalog[$hex]
        return [pscustomobject]@{
            Code  = $hex
            Name  = $e.Name
            Area  = $e.Area
            Means = $e.Means
            Fix   = $e.Fix
            Known = $true
        }
    }

    # Not catalogued. We can still say something useful: the high word of an
    # HRESULT identifies the component that produced it, which is usually
    # enough to know which log to go read next.
    $facility = 'unknown component'
    switch -Wildcard ($hex) {
        '0x8024*' { $facility = 'the Windows Update Agent'; break }
        '0x800F*' { $facility = 'Windows servicing (CBS)'; break }
        '0x8004*' { $facility = 'WMI or COM'; break }
        '0x87D*'  { $facility = 'the Configuration Manager client'; break }
        '0x8019*' { $facility = 'BITS (HTTP status)'; break }
        '0x8020*' { $facility = 'BITS'; break }
        '0x8009*' { $facility = 'Windows cryptography'; break }
        '0x800B*' { $facility = 'certificate validation'; break }
        '0x8007*' { $facility = 'a Win32 API'; break }
    }

    [pscustomobject]@{
        Code  = $hex
        Name  = '(uncatalogued)'
        Area  = 'Unknown'
        Means = "Not in the built-in catalogue. Source appears to be: $facility."
        Fix   = "Search for $hex together with the component name from the log line."
        Known = $false
    }
}


function Resolve-MDPattern {
    <# Returns the first message-pattern entry that matches, or $null. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Message,
        [string] $LogName
    )

    if ([string]::IsNullOrWhiteSpace($Message)) { return $null }

    foreach ($p in $script:MDPatternCatalog) {
        if ($p.Log -and $LogName -and ($p.Log -ne $LogName)) { continue }
        if ($Message -match $p.Match) {
            return [pscustomobject]@{
                Area  = $p.Area
                Means = $p.Means
                Fix   = $p.Fix
            }
        }
    }
    $null
}
