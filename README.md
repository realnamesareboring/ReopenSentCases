# Sentinel Incident Auto-Reopener

This Azure Function automatically reopens Microsoft Sentinel incidents that are closed with "Undetermined" classification and remain unassigned. It helps ensure incidents requiring further analysis don't get overlooked.

## Prerequisites

- Azure subscription with Microsoft Sentinel workspace
- Contributor access to the resource group
- Azure CloudShell access

## Architecture

The solution consists of:
- Azure Function App (Python 3.11)
- Service Principal for authentication
- HTTP trigger endpoint for incident processing

## Deployment Steps

### Step 1: Deploy Infrastructure (Azure Portal)

1. Download the `deploy-template.json` ARM template
2. Go to **Azure Portal** → **Template deployment (deploy a custom template)**
3. Click **Build your own template in the editor**
4. Copy and paste the ARM template JSON content
5. Click **Save**
6. Fill in the parameters:
   - **Subscription**: Your Azure subscription
   - **Resource Group**: Your target resource group (e.g., `yoursentinelworkspacerg`)
   - **Sentinel Workspace Name**: Your Sentinel workspace name (e.g., `YOUR-SENTINEL-01`)
   - **Function App Name**: Leave default or customize (e.g., `sentinel-reopen-ulj2oekpdeta6`)
   - **Subscription Id**: Your subscription ID
   - **Resource Group Name**: The resource group containing your Sentinel workspace (e.g., `RG-SENT-WKSPCE`)
7. Click **Review + create** → **Create**

**Note**: The deployment creates the Function App infrastructure but no function code yet.

### Step 2: Deploy Function Code (Azure CloudShell)

1. Open **Azure CloudShell** (PowerShell)
2. Edit the script with your actual values:
```powershell
# Edit the deployment script
code deploy-function.ps1

# Update these variables:
# $FunctionAppName = "sentinel-reopen-ulj2oekpdeta6"      
# $ResourceGroupName = "rg-sentcase-func"
```

3. Upload the PowerShell script in the Azure CloudShell under **Manage files** → **Upload**

4. Run the deployment:
```powershell
./deploy-builtin-only.ps1
```

### Step 3: Create Service Principal

Due to infrastructure limitations with Managed Identity, we use Service Principal authentication.

1. Create the Service Principal:
```bash
az ad sp create-for-rbac --name "sentinel-function-sp" --role "Microsoft Sentinel Contributor" --scopes "/subscriptions/YOUR_SUBSCRIPTION_ID/resourceGroups/YOUR_SENTINEL_RESOURCE_GROUP"
```

2. **Important**: Save the output values:
   - `appId` (Client ID)
   - `password` (Client Secret)
   - `tenant` (Tenant ID)

### Step 4: Configure Authentication

Add the Service Principal credentials to your Function App:

```bash
# Replace with your actual values from Step 3
az functionapp config appsettings set --name "yourfunction" --resource-group "yourfunctionrg" --settings AZURE_CLIENT_ID="your-app-id"

az functionapp config appsettings set --name "yourfunction" --resource-group "yourfunctionrg" --settings AZURE_CLIENT_SECRET="your-password"

az functionapp config appsettings set --name "yourfunction" --resource-group "yourfunctionrg" --settings AZURE_TENANT_ID="your-tenant-id"
```

### Step 5: Get Function Access Key

```bash
az functionapp function keys list --name "yourfunction" --resource-group "yourfunctionrg" --function-name "reopen_incidents"
```

Save the `default` key value for testing.

## Testing

### Create Test Incident 

To create a test scenario that meets the function criteria:

1. **Create a New Incident**:
   - Go to **Microsoft Sentinel** → **Incidents**
   - Click **Create incident** (or wait for an actual security alert)
   - Set the following properties:
     - **Status**: `New`
     - **Owner**: Leave `Unassigned`
     - **Severity**: Any level
     - **Title**: `Test Incident for Auto-Reopener`

2. **Close the Incident with Target Criteria**:
   - Open the incident you just created
   - Click **Actions** → **Close incident**
   - Set the closure details:
     - **Classification**: `Undetermined`
     - **Owner**: Leave `Unassigned` (do not assign to anyone)
     - **Comment**: `Closing for auto-reopener testing`
   - Click **Apply**

### Test the Function

```bash
curl "https://YOUR_FUNCTION_APP.azurewebsites.net/api/reopen_incidents?code=YOUR_FUNCTION_KEY"
```

### Expected Response

```json
{
  "success": true,
  "message": "Sentinel incident reopening function completed successfully",
  "summary": {
    "totalIncidentsAnalyzed": 1,
    "incidentsReopened": 1,
    "executionTime": "2025-09-17T17:20:37.119751Z",
    "sentinelWorkspace": "YOUR-SENTINEL-01"
  },
  "criteria": {
    "status": "Closed",
    "assignment": "Unassigned",
    "classification": "Undetermined"
  },
  "incidentDetails": [
    {
      "incidentNumber": 60495,
      "title": "Sample Incident",
      "status": "Closed",
      "classification": "Undetermined",
      "reopened": true,
      "action": "reopened"
    }
  ]
}
```
