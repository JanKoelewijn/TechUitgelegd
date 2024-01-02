<#
.SYNOPSIS
Automatisering van Azure DevOps Taakcreatie voor Verlopende Entra ID App Registratie Secrets

.DESCRIPTION
Dit script automatiseert het proces van identificeren en reageren op verlopende Entra ID App Registratie Secrets. Het gebruikt Microsoft Graph en Azure DevOps API om een naadloze workflow te bieden voor IT-beheerders en DevOps-teams.

Hoofddoelen en Functies:
- Entra ID Monitoring: Doorzoekt alle App Registraties in Entra ID op secrets die binnen een gespecificeerde tijdsperiode zullen verlopen.
- DevOps Taakcreatie: Creëert automatisch een nieuwe taak in Azure DevOps voor elke geïdentificeerde verlopende secret.

Gebruikte Technologieën en Methodes:
- PowerShell voor scriptorchestratie en datamanipulatie.
- Microsoft Graph API voor het ophalen van details over Entra ID App Registraties en hun secrets.
- Azure DevOps API voor het automatisch creëren van taken.
- KeyVault Certificaat voor app registratie en Secret voor PAT

GEBRUIKSINSTRUCTIES:
- Uit te voeren in een Azure Automation omgeving.
- Vereist een App Registratie in Entra ID met certificaat authenticatie.
- Configuratie van verschillende variabelen in Azure Automations vereist.

BIJZONDERHEDEN:
- Biedt een efficiënte oplossing voor Entra ID en Azure DevOps beheer.

VARIABLEN DIE NODIG ZIJN IN AUTOMATION ACCOUNT:

Name / Type / Uitleg
GetAppSecrets_ClientID / String / Appregistratie ID
Tenant_ID / String / Tenant ID waar de Appregistratie in zit en welke we uitlezen
GetAppSecret_CertificatThumb / String / De Thumbprint van het certificaat waarmee we gaan authenticeren
GetAppSecretsDaysToExpire / Interger / Dagen vooruit voordat secret verloopt 31 (maand)
KeyVault / String / Keyvault naam waaruit we secret gaan halen
DevOps_WorkItemType / String / Type werk item wat aangemaakt moet worden voor nu gebruiken we TASK
DevOps_WorkItemTitle / String / Titel van task waarmee deze begint : App Registratie Secret Verloopt
DevOps_OrganizationName / String / Organisatie naam van DevOps waarin de tasks aangemaakt moeten worden
DevOps_ProjectName / String / Projectnaam van DevOps Board waarin de tasks aangemaakt moeten worden
DevOps_WorkParentID / Interger / Onder welke UserStory moeten de gemaakte items gelinkt worden

.NOTES
Auteur: Jan Koelewijn
Versie: 1.0 (DUTCH)
#>



#Vars for Main Tasks
$ClientID_Automation = Get-AutomationVariable -Name 'GetAppSecrets_ClientID'
$TenantID = Get-AutomationVariable -Name 'Tenant_ID'
$CertifcateThumPrint = Get-AutomationVariable -Name 'GetAppSecrets_CertificateThumb'
$DaysToExpire = Get-AutomationVariable -Name 'GetAppSecrets_DaysToExpire'

#Authentication in Azure DevOps
$VaultName = Get-AutomationVariable -Name "KeyVault"

$AzureDevOpsPAT = Get-AzKeyVaultSecret `
-VaultName $VaultName `
-Name "PATDevOps" `
-AsPlainText -DefaultProfile $AzureContext
$AzureDevOpsAuthenicationHeader = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($AzureDevOpsPAT)")) }

$OrganizationName = Get-AutomationVariable -Name 'DevOps_OrganizationName'
$UriOrganization = "https://dev.azure.com/$($OrganizationName)/"


#Lists all projects in your organization
$uriAccount = $UriOrganization + "_apis/projects?api-version=5.1"
Invoke-RestMethod -Uri $uriAccount -Method get -Headers $AzureDevOpsAuthenicationHeader 


#Create a work item

$WorkItemType = Get-AutomationVariable -Name 'DevOps_WorkItemType'
$WorkItemTitle = Get-AutomationVariable -Name 'DevOps_WorkItemTitle' #"App Registratie Secret Verloopt"
$ProjectName = Get-AutomationVariable -Name 'DevOps_ProjectName'
$parentWorkItemId = Get-AutomationVariable -Name 'DevOps_WorkParentID' 


$uri = $UriOrganization + $ProjectName + "/_apis/wit/workitems/$" + $WorkItemType + "?api-version=5.1"


# Connect to Microsoft Graph
Connect-MgGraph `
    -ClientId $ClientID_Automation `
    -TenantId $TenantID  `
    -CertificateThumbprint $CertifcateThumPrint `
    -NoWelcome
# Retrieve all applications
$allApplications = @()
$pageSize = 100
$nextLink = $null
 
do {
    $applicationsPage = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/applications\$($nextLink -replace '\?', '&')"
 
    $allApplications += $applicationsPage.Value
 
    $nextLink = $applicationsPage.'@odata.nextLink'
} while ($nextLink)
 
# Query each application
foreach ($application in $allApplications) {
    
    
     
# Retrieve secrets
    $secretsUri = "https://graph.microsoft.com/v1.0/applications/$($application.id)/passwordCredentials"
    $secrets = Invoke-MgGraphRequest -Method GET -Uri $secretsUri
 
# Query secrets
    foreach ($secret in $secrets.value) {
        try {
            $expiryDateTime = [DateTime]$secret.endDateTime
            $expiryDate = $expiryDateTime.Date
 
            if ($expiryDate -ne $null) {
                $daysUntilExpiry = ($expiryDate - (Get-Date).Date).Days
 
                if ($daysUntilExpiry -le $DaysToExpire) {
                    Write-Output "Secret Expiring within a $DaysToExpire Days:"
                    Write-Output "Application Name: $($application.displayName)"
                    Write-Output "Application ID: $($application.id)"
                    Write-Output "  Key ID: $($secret.keyId)"
                    Write-Output "  Expiry Date: $($expiryDate.ToString("yyyy-MM-dd"))"
                    Write-Output "  Days Until Expiry: $daysUntilExpiry"


                    
                $body = @"
                [
                  {
                    "op": "add",
                    "path": "/fields/System.Title",
                    "value": "$WorkItemTitle $($application.displayName)"
                  },
                  {
                    "op": "add",
                    "path": "/fields/System.Description",
                    "value": "De Applicatie $($application.displayName), heeft een secret  Key ID: $($secret.keyId) welke verloopt op Expiry Date: $($expiryDate.ToString("yyyy-MM-dd")) dit zijn nog $daysUntilExpiry dagen."
                  },
                  {
                    "op": "add",
                    "path": "/relations/-",
                    "value": {
                        "rel": "System.LinkTypes.Hierarchy-Reverse",
                        "url": "https://dev.azure.com/$organization/$project/_apis/wit/workItems/$parentWorkItemId",
                        "attributes": {
                            "comment": "Linking to parent item"
                                      }
                             }
                  }
                ]
"@

Invoke-RestMethod -Uri $uri -Method POST -Headers $AzureDevOpsAuthenicationHeader -ContentType "application/json-patch+json" -Body $body
                }
            } else {
                throw "Invalid DateTime format"
            }
        }
        catch {
            Write-Output "Error parsing secret expiry date. Skipping secret."
        }
    }
 
}
 
# Disconnect from Microsoft Graph
Disconnect-MgGraph
