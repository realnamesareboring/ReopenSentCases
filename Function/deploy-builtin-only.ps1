# Deploy Function with Built-in Libraries Only (No requirements.txt)
$FunctionAppName = "your function name"      
$ResourceGroupName = "function resource group"

Write-Host "Deploying Sentinel Function (Built-in Libraries Only)..." -ForegroundColor Green
Write-Host "Function App: $FunctionAppName" -ForegroundColor Yellow
Write-Host "Resource Group: $ResourceGroupName" -ForegroundColor Yellow

# Check Azure CLI
try {
    $null = az account show 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Azure CLI not found or not logged in. Please run 'az login' first." -ForegroundColor Red
        exit 1
    }
    Write-Host "Azure CLI authenticated" -ForegroundColor Green
} catch {
    Write-Host "Azure CLI not available" -ForegroundColor Red
    exit 1
}

# Create temporary directory
$tempDir = New-TemporaryFile | %{ Remove-Item $_; New-Item -ItemType Directory -Path $_ }
Write-Host "Created temporary directory: $tempDir" -ForegroundColor Cyan

try {
    # Create host.json (minimal)
    Write-Host "Creating host.json..." -ForegroundColor Cyan
    @'
{
    "version": "2.0",
    "extensionBundle": {
        "id": "Microsoft.Azure.Functions.ExtensionBundle",
        "version": "[4.*, 5.0.0)"
    },
    "functionTimeout": "00:05:00",
    "logging": {
        "applicationInsights": {
            "samplingSettings": {
                "isEnabled": true
            }
        }
    }
}
'@ | Out-File -FilePath "$tempDir/host.json" -Encoding utf8

    # NOTE: Deliberately NOT creating requirements.txt since that's what's breaking it
    Write-Host "Skipping requirements.txt (using built-in libraries only)..." -ForegroundColor Yellow

    # Create function_app.py with the full built-in-only code
    Write-Host "Creating function_app.py with built-in libraries..." -ForegroundColor Cyan
    
    # The complete function code (from the previous artifact)
    $functionCode = Get-Content -Raw -Path "function_app.py" -ErrorAction SilentlyContinue
    
    if (-not $functionCode) {
        # If the file doesn't exist, create the content inline
        $functionCode = @'
import azure.functions as func
import logging
import json
import urllib.request
import urllib.parse
import urllib.error
import os
from datetime import datetime, timedelta
import uuid

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)

@app.route(route="reopen_incidents")
def reopen_incidents(req: func.HttpRequest) -> func.HttpResponse:
    logging.info('Sentinel incident reopening function triggered.')
    
    # Handle CORS for browser requests
    headers = {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': 'https://portal.azure.com',
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization'
    }
    
    if req.method == 'OPTIONS':
        return func.HttpResponse('', status_code=200, headers=headers)
    
    try:
        # Get configuration from environment variables
        subscription_id = os.environ.get('SENTINEL_SUBSCRIPTION_ID')
        resource_group = os.environ.get('SENTINEL_RESOURCE_GROUP')
        workspace_name = os.environ.get('SENTINEL_WORKSPACE_NAME')
        
        if not all([subscription_id, resource_group, workspace_name]):
            error_msg = 'Missing required environment variables'
            logging.error(error_msg)
            return func.HttpResponse(
                json.dumps({'error': error_msg}),
                status_code=500,
                mimetype='application/json',
                headers=headers
            )
        
        # Get access token using Managed Identity
        token = get_access_token()
        if not token:
            error_msg = 'Failed to authenticate with Azure using Managed Identity'
            logging.error(error_msg)
            return func.HttpResponse(
                json.dumps({'error': error_msg}),
                status_code=500,
                mimetype='application/json',
                headers=headers
            )
        
        # Calculate one hour ago timestamp
        one_hour_ago = (datetime.utcnow() - timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%S.%fZ')
        
        # Get recently closed incidents
        incidents = get_recently_closed_incidents(token, subscription_id, resource_group, workspace_name, one_hour_ago)
        if incidents is None:
            error_msg = 'Failed to fetch incidents from Microsoft Sentinel'
            return func.HttpResponse(
                json.dumps({'error': error_msg}),
                status_code=500,
                mimetype='application/json',
                headers=headers
            )
        
        # Process incidents
        results = process_incidents(token, incidents)
        
        response = {
            'success': True,
            'message': 'Sentinel incident reopening function completed successfully',
            'summary': {
                'totalIncidentsAnalyzed': len(incidents),
                'incidentsReopened': results['reopened_count'],
                'executionTime': datetime.utcnow().isoformat() + 'Z',
                'sentinelWorkspace': workspace_name
            },
            'criteria': {
                'status': 'Closed',
                'assignment': 'Unassigned',
                'classification': 'Undetermined'
            },
            'incidentDetails': results['details']
        }
        
        return func.HttpResponse(
            json.dumps(response, indent=2),
            status_code=200,
            mimetype='application/json',
            headers=headers
        )
        
    except Exception as e:
        error_msg = f'Function execution failed: {str(e)}'
        logging.error(error_msg, exc_info=True)
        return func.HttpResponse(
            json.dumps({
                'success': False,
                'error': error_msg,
                'timestamp': datetime.utcnow().isoformat() + 'Z'
            }),
            status_code=500,
            mimetype='application/json',
            headers=headers
        )

def http_request(url, method='GET', data=None, headers=None, timeout=30):
    """Make HTTP requests using urllib instead of requests library"""
    try:
        if headers is None:
            headers = {}
        
        if data is not None:
            if isinstance(data, dict):
                data = json.dumps(data).encode('utf-8')
                headers['Content-Type'] = 'application/json'
            elif isinstance(data, str):
                data = data.encode('utf-8')
        
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        
        with urllib.request.urlopen(req, timeout=timeout) as response:
            response_data = response.read().decode('utf-8')
            status_code = response.getcode()
            
            content_type = response.headers.get('content-type', '')
            if 'application/json' in content_type:
                try:
                    response_data = json.loads(response_data)
                except json.JSONDecodeError:
                    pass
            
            return {
                'status_code': status_code,
                'data': response_data,
                'success': 200 <= status_code < 300
            }
            
    except urllib.error.HTTPError as e:
        error_data = e.read().decode('utf-8') if e.read() else str(e)
        return {'status_code': e.code, 'data': error_data, 'success': False, 'error': str(e)}
    except Exception as e:
        return {'status_code': 0, 'data': None, 'success': False, 'error': str(e)}

def get_access_token():
    """Get access token using Managed Identity with urllib"""
    try:
        url = 'http://169.254.169.254/metadata/identity/oauth2/token'
        params = {'api-version': '2018-02-01', 'resource': 'https://management.azure.com/'}
        query_string = urllib.parse.urlencode(params)
        full_url = f"{url}?{query_string}"
        headers = {'Metadata': 'true'}
        
        response = http_request(full_url, headers=headers, timeout=10)
        
        if response['success']:
            token_data = response['data']
            return token_data['access_token']
        else:
            logging.error(f'Failed to get access token: {response["error"]}')
            return None
    except Exception as e:
        logging.error(f'Error getting access token: {str(e)}')
        return None

def get_recently_closed_incidents(token, subscription_id, resource_group, workspace_name, one_hour_ago):
    """Get incidents closed within the past hour"""
    try:
        base_uri = f'https://management.azure.com/subscriptions/{subscription_id}/resourceGroups/{resource_group}/providers/Microsoft.OperationalInsights/workspaces/{workspace_name}/providers/Microsoft.SecurityInsights'
        
        params = {
            'api-version': '2023-02-01',
            '$filter': f"properties/status eq 'Closed' and properties/lastModifiedTimeUtc gt {one_hour_ago}",
            '$orderby': 'properties/lastModifiedTimeUtc desc',
            '$top': '200'
        }
        
        query_string = urllib.parse.urlencode(params)
        url = f'{base_uri}/incidents?{query_string}'
        headers = {'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'}
        
        response = http_request(url, headers=headers, timeout=30)
        
        if response['success']:
            data = response['data']
            incidents = data.get('value', []) if isinstance(data, dict) else []
            return incidents
        else:
            logging.error(f'Failed to get incidents: {response.get("error", "Unknown error")}')
            return None
    except Exception as e:
        logging.error(f'Error fetching incidents: {str(e)}')
        return None

def process_incidents(token, incidents):
    """Process each incident and reopen if it meets criteria"""
    reopened_count = 0
    details = []
    
    for incident in incidents:
        try:
            incident_id = incident['id']
            properties = incident['properties']
            incident_number = properties.get('incidentNumber', 'Unknown')
            
            incident_info = {
                'incidentNumber': incident_number,
                'title': properties.get('title', 'No title'),
                'status': properties.get('status'),
                'classification': properties.get('classification'),
                'reopened': False
            }
            
            if meets_reopening_criteria(properties):
                if reopen_incident(token, incident_id, properties):
                    add_reopening_comment(token, incident_id, incident_number)
                    reopened_count += 1
                    incident_info['reopened'] = True
                    incident_info['action'] = 'reopened'
                else:
                    incident_info['action'] = 'failed_to_reopen'
            else:
                incident_info['action'] = 'skipped'
            
            details.append(incident_info)
            
        except Exception as e:
            details.append({'incidentNumber': 'unknown', 'action': 'error', 'error': str(e)})
    
    return {'reopened_count': reopened_count, 'details': details}

def meets_reopening_criteria(properties):
    """Check if incident meets all criteria for reopening"""
    if properties.get('status') != 'Closed':
        return False
    if properties.get('classification') != 'Undetermined':
        return False
    owner = properties.get('owner')
    if owner is None:
        return True
    if isinstance(owner, dict):
        assigned_to = owner.get('assignedTo')
        if assigned_to is None or assigned_to == '':
            return True
    return False

def reopen_incident(token, incident_id, properties):
    """Reopen an incident by changing status to Active"""
    try:
        url = f'https://management.azure.com{incident_id}?api-version=2023-02-01'
        headers = {'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'}
        body = {
            'properties': {
                'title': properties.get('title'),
                'status': 'Active',
                'severity': properties.get('severity'),
                'classification': None
            }
        }
        
        response = http_request(url, method='PUT', data=body, headers=headers, timeout=30)
        return response['success']
    except Exception as e:
        logging.error(f'Error reopening incident: {str(e)}')
        return False

def add_reopening_comment(token, incident_id, incident_number):
    """Add a comment explaining why the incident was reopened"""
    try:
        comment_id = str(uuid.uuid4())
        url = f'https://management.azure.com{incident_id}/comments/{comment_id}?api-version=2023-02-01'
        headers = {'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'}
        timestamp = datetime.utcnow().isoformat() + 'Z'
        comment_message = f"Incident automatically reopened due to undetermined classification and unassigned status. Reopened on {timestamp} by Sentinel automation function."
        body = {'properties': {'message': comment_message}}
        
        response = http_request(url, method='PUT', data=body, headers=headers, timeout=30)
        return response['success']
    except Exception as e:
        logging.error(f'Failed to add comment: {str(e)}')
        return False
'@
    }
    
    $functionCode | Out-File -FilePath "$tempDir/function_app.py" -Encoding utf8

    # Create zip package
    Write-Host "Creating deployment package..." -ForegroundColor Cyan
    $zipPath = "$tempDir/function-package.zip"
    # Only include host.json and function_app.py - NO requirements.txt
    Compress-Archive -Path "$tempDir/host.json", "$tempDir/function_app.py" -DestinationPath $zipPath

    Write-Host "Package contents:" -ForegroundColor Gray
    Get-ChildItem $tempDir | Format-Table Name, Length

    # Deploy using Azure CLI
    Write-Host "Deploying to Azure Function App..." -ForegroundColor Green
    $deployResult = az functionapp deployment source config-zip --name $FunctionAppName --resource-group $ResourceGroupName --src $zipPath 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Function code deployed successfully!" -ForegroundColor Green
        
        # Wait for deployment to process
        Write-Host "Waiting for function to initialize..." -ForegroundColor Yellow
        Start-Sleep -Seconds 30
        
        # Get function URL and test
        $functionApp = az functionapp show --name $FunctionAppName --resource-group $ResourceGroupName --query "defaultHostName" --output tsv
        $functionUrl = "https://$functionApp/api/reopen_incidents"
        
        Write-Host "Deployment completed successfully!" -ForegroundColor Green
        Write-Host "Function URL: $functionUrl" -ForegroundColor Yellow
        
        # Test the function
        Write-Host "Testing function..." -ForegroundColor Cyan
        try {
            $testResponse = Invoke-RestMethod -Uri $functionUrl -Method GET -ErrorAction Stop
            Write-Host "SUCCESS: Function is responding!" -ForegroundColor Green
            Write-Host ($testResponse | ConvertTo-Json -Depth 3) -ForegroundColor White
        } catch {
            Write-Host "Function deployed but not responding yet. Check logs in Azure Portal." -ForegroundColor Yellow
            Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Gray
        }
        
    } else {
        Write-Host "Deployment failed:" -ForegroundColor Red
        Write-Host $deployResult -ForegroundColor Red
    }
    
} catch {
    Write-Host "Deployment failed: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    # Cleanup
    Write-Host "Cleaning up temporary files..." -ForegroundColor Gray
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`nNext steps:" -ForegroundColor Cyan
Write-Host "1. Check Azure Portal > Function App > Functions to see 'reopen_incidents'" -ForegroundColor White
Write-Host "2. Grant Sentinel permissions to the managed identity" -ForegroundColor White
Write-Host "3. Test the function using the URL above" -ForegroundColor White