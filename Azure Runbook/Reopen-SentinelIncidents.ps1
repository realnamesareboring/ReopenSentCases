#Requires -Modules Az.Accounts, Az.SecurityInsights

<#
.SYNOPSIS
    Automatically reopens Microsoft Sentinel incidents that meet specific criteria.

.DESCRIPTION
    This runbook identifies and reopens Microsoft Sentinel incidents that are:
    - Status: Closed
    - Classification: Undetermined  
    - Owner: Unassigned
    - Closed within a specified time window
    
    The script adds audit comments to all reopened incidents for compliance tracking.

.PARAMETER SubscriptionId
    The Azure subscription ID containing the Sentinel workspace.

.PARAMETER ResourceGroupName
    The resource group name containing the Sentinel workspace.

.PARAMETER WorkspaceName
    The name of the Log Analytics workspace with Sentinel enabled.

.PARAMETER TimeWindowHours
    Number of hours to look back for recently closed incidents. Default is 0.083 hours (5 minutes).
    Examples: 0.083 = 5 minutes, 0.25 = 15 minutes, 1 = 1 hour, 24 = 24 hours

.NOTES
    Author: Jose Torrico
    Version: 1.0
    Requires: Microsoft Sentinel Responder role on the workspace
#>

#Requires -Modules Az.Accounts, Az.SecurityInsights

# All configuration comes from Automation Variables - no manual input required
$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"

try {
    # Read all configuration from Variables blade
    Write-Output "Reading configuration from Automation Variables..."
    $SubscriptionId = Get-AutomationVariable -Name "SentinelSubscriptionId"
    $ResourceGroupName = Get-AutomationVariable -Name "SentinelResourceGroup"
    $WorkspaceName = Get-AutomationVariable -Name "SentinelWorkspaceName"
    $TimeWindowHours = [double](Get-AutomationVariable -Name "DefaultTimeWindowHours")

    Write-Output "Starting Microsoft Sentinel Incident Reopening Process"
    Write-Output "Subscription ID: $SubscriptionId"
    Write-Output "Resource Group: $ResourceGroupName"
    Write-Output "Workspace Name: $WorkspaceName"
    Write-Output "Time Window: $TimeWindowHours hours"
    Write-Output "Execution Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')"
    Write-Output "----------------------------------------"

    # Connect using Managed Identity
    Write-Output "Authenticating with Managed Identity..."
    $context = Connect-AzAccount -Identity
    Write-Output "Successfully authenticated as: $($context.Context.Account.Id)"

    # Set subscription context
    Write-Output "Setting subscription context to: $SubscriptionId"
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    $currentContext = Get-AzContext
    Write-Output "Active subscription: $($currentContext.Subscription.Name)"

    # Import required modules
    Write-Output "Importing SecurityInsights module..."
    Import-Module Az.SecurityInsights -Force

    # Calculate time filter
    $cutoffTime = (Get-Date).AddHours(-$TimeWindowHours)
    Write-Output "Searching for incidents closed after: $($cutoffTime.ToString('yyyy-MM-dd HH:mm:ss UTC'))"

    # Get incidents
    Write-Output "Retrieving incidents from Sentinel workspace..."
    $allIncidents = Get-AzSentinelIncident -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName
    Write-Output "Successfully retrieved $($allIncidents.Count) total incidents"

    # Apply filtering with early exit optimization
    Write-Output "Applying filters to identify target incidents..."
    $targetIncidents = @()
    $processedCount = 0
    
    # Sort by LastModifiedTimeUtc descending for early exit
    $sortedIncidents = $allIncidents | Sort-Object LastModifiedTimeUtc -Descending
    
    foreach ($incident in $sortedIncidents) {
        $processedCount++
        
        # Early exit if incident is older than time window
        if ($incident.LastModifiedTimeUtc -le $cutoffTime) {
            $skippedCount = $allIncidents.Count - $processedCount + 1
            Write-Output "Early exit: Found incident older than time window. Skipping remaining $skippedCount incidents."
            break
        }
        
        # Apply all filters
        if ($incident.Status -eq "Closed" -and
            $incident.Classification -eq "Undetermined" -and
            ($incident.Owner -eq $null -or $incident.Owner.Email -eq $null -or $incident.Owner.Email -eq "")) {
            
            $targetIncidents += $incident
            Write-Output "Found matching incident: #$($incident.IncidentNumber) - $($incident.Title)"
        }
        
        # Progress indicator
        if ($processedCount % 1000 -eq 0) {
            Write-Output "Processed $processedCount incidents..."
        }
    }

    Write-Output "Filter Results:"
    Write-Output "  Total incidents in workspace: $($allIncidents.Count)"
    Write-Output "  Incidents processed: $processedCount"
    Write-Output "  Target incidents (matching all criteria): $($targetIncidents.Count)"

    if ($targetIncidents.Count -eq 0) {
        Write-Output "No incidents found matching the specified criteria."
        Write-Output "Criteria: Status=Closed, Classification=Undetermined, Owner=Unassigned, Closed within $TimeWindowHours hours"
        Write-Output "Process completed - no action required."
        return
    }

    # Display target incidents
    Write-Output "Incidents identified for reopening:"
    foreach ($incident in $targetIncidents) {
        Write-Output "  Incident Number: $($incident.IncidentNumber)"
        Write-Output "  Title: $($incident.Title)"
        Write-Output "  Status: $($incident.Status)"
        Write-Output "  Classification: $($incident.Classification)"
        Write-Output "  Owner: $(if($incident.Owner.Email) { $incident.Owner.Email } else { 'Unassigned' })"
        Write-Output "  Closed Time: $($incident.LastModifiedTimeUtc)"
        Write-Output "  ---"
    }

    # Process incidents for reopening
    Write-Output "Beginning incident reopening process..."
    $reopenedCount = 0
    $failedCount = 0

    foreach ($incident in $targetIncidents) {
        $incidentId = $incident.Name
        $incidentNumber = $incident.IncidentNumber
        $incidentTitle = $incident.Title

        Write-Output "Processing Incident #$incidentNumber - '$incidentTitle'"

        try {
            # Update incident status
            Write-Output "  Updating incident status to Active..."
            Update-AzSentinelIncident -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -IncidentId $incidentId -Status "Active" -Title $incidentTitle -Severity $incident.Severity

            # Verify the status change
            Start-Sleep -Seconds 2
            $updatedIncident = Get-AzSentinelIncident -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -IncidentId $incidentId
            
            if ($updatedIncident.Status -eq "Active") {
                Write-Output "  Successfully updated incident status to Active"
                
                # Add audit comment
                try {
                    $auditComment = "Incident automatically reopened due to undetermined closure reason and unassigned status. Reopened by automated process on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')."
                    New-AzSentinelIncidentComment -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -IncidentId $incidentId -Message $auditComment
                    Write-Output "  Audit comment added successfully"
                } catch {
                    Write-Output "  Warning: Failed to add audit comment: $($_.Exception.Message)"
                }

                $reopenedCount++
                Write-Output "  Incident #$incidentNumber processing completed successfully"

            } else {
                Write-Output "  Warning: Status verification failed - incident status is: $($updatedIncident.Status)"
                $failedCount++
            }

        } catch {
            Write-Output "  Error: Failed to process Incident #$incidentNumber : $($_.Exception.Message)"
            $failedCount++
        }

        Start-Sleep -Milliseconds 500
    }

    # Final summary
    Write-Output "----------------------------------------"
    Write-Output "Process Execution Summary:"
    Write-Output "  Execution completed at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')"
    Write-Output "  Total incidents identified: $($targetIncidents.Count)"
    Write-Output "  Successfully reopened: $reopenedCount"
    Write-Output "  Failed to reopen: $failedCount"
    Write-Output "  Success rate: $(if($targetIncidents.Count -gt 0) { [math]::Round(($reopenedCount / $targetIncidents.Count) * 100, 2) } else { 0 })%"

    Write-Output "Microsoft Sentinel Incident Reopening Process completed successfully."

} catch {
    Write-Error "Critical error in runbook execution: $($_.Exception.Message)"
    throw
}