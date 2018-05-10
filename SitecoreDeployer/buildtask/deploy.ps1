#getting data from task
$ArmTemplatePath = Get-VstsInput -Name armTemplatePath -Require
$ArmParametersPath = Get-VstsInput -Name armParametersPath -Require
$RgName = Get-VstsInput -Name resourceGroupName -Require
$location = Get-VstsInput -Name location -Require
$DeploymentType = Get-VstsInput -Name deploymentType -Require
#get input for generate SAS
$generateSasInput = Get-VstsInput -Name generateSas -Require
#convert it to Boolean
$GenerateSas = [System.Convert]::ToBoolean($generateSasInput)
#get license location
$licenseLocation = Get-VstsInput -Name licenseLocation -Require

#get input for security features
#PRC role
$limitPrcAccessInput = Get-VstsInput -Name limitAccesToPrc -Require
$limitPrcAccess = [System.Convert]::ToBoolean($limitPrcAccessInput)
$instanceNamePrc = Get-VstsInput -Name prcInstanceName;
#REP role
$limitRepAccessInput = Get-VstsInput -Name limitAccesToRep -Require
$instanceNameRep = Get-VstsInput -Name repInstanceName;

#users IP/Mask list as string
$ipList = Get-VstsInput -Name ipMaskCollection;


Import-Module $PSScriptRoot\ps_modules\TlsHelper_
Add-Tls12InSession
Import-Module $PSScriptRoot\ps_modules\VstsAzureHelpers_
Initialize-Azure

Import-Module $PSScriptRoot\functions-module-v1.psm1
#region Create Params Object
# license file needs to be secure string and adding the params as a hashtable is the only way to do it
$additionalParams = New-Object -TypeName Hashtable;

$params = Get-Content $ArmParametersPath -Raw | ConvertFrom-Json;

#check template - what parameter is used to limit access to CM and PRC role in template
if ($limitPrcAccess) {
    $clientIpString = "security_clientIp"
    $clientMaskString = "security_clientIpMask"
    #parse template - which parameter is used for ip security
    if (Select-String -Path $ArmTemplatePath -Pattern $clientIpString -SimpleMatch -Quiet) {
        #do nothing, we are OK
    } elseif (Select-String -Path $ArmTemplatePath -Pattern "securityClientIp" -SimpleMatch -Quiet) {
        $clientIpString = "securityClientIp"
        $clientMaskString = "securityClientIpMask"
    } else {
        #we are not finding known strings for limiting PRC access
        $limitPrcAccess = $False
        Write-Host "##vso[task.logissue type=warning;] LimitAccessToInstance: Access to PRC role shall not be limited by task, as we could not figure out template parameter for this"
    }
}

$ipSecuritySetInTemplateParams = $False

foreach($p in $params | Get-Member -MemberType *Property) {
    #if we need to limit access to processing - we need to check, if it is not limited already at template parameters
    if ($limitPrcAccess) {
        if ($p.Name.ToLower() -eq $clientIpString.ToLower()) {
            Write-Host "##vso[task.logissue type=warning;] LimitAccessToInstance: Access to PRC role shall not be limited by task - it is limited in template"
            $ipSecuritySetInTemplateParams = $True
        }
    }
	# Check if the parameter is a reference to a Key Vault secret
	if (($params.$($p.Name).reference) -and
		($params.$($p.Name).reference.keyVault) -and
		($params.$($p.Name).reference.keyVault.id) -and
		($params.$($p.Name).reference.secretName)){
		$vaultName = Split-Path $params.$($p.Name).reference.keyVault.id -Leaf
        $secretName = $params.$($p.Name).reference.secretName
        if (CheckIfPossiblyUriAndIfNeedToGenerateSas -name $p.Name -generate $GenerateSas) {
            #if parameter name contains msdeploy or url - it is great point of deal that we have URL to our package here
            $secret = TryGenerateSas -maybeStorageUri (Get-AzureKeyVaultSecret -VaultName $vaultName -Name $secretName).SecretValueText
            Write-Debug "URI text is $secret"
        } else {
            $secret = (Get-AzureKeyVaultSecret -VaultName $vaultName -Name $secretName).SecretValue
        }

		$additionalParams.Add($p.Name, $secret);
	} else {
        # or a normal plain text parameter
        if (CheckIfPossiblyUriAndIfNeedToGenerateSas -name $p.Name -generate $GenerateSas) {
            $tempUrlForMessage = $params.$($p.Name).value
            Write-Verbose "We are going to generate SAS for $tempUrlForMessage"
            #process replacement here
            $valueToAdd = TryGenerateSas -maybeStorageUri $params.$($p.Name).value
            $additionalParams.Add($p.Name, $valueToAdd);
            Write-Verbose "URI text is $valueToAdd"
        } else {
            $additionalParams.Add($p.Name, $params.$($p.Name).value);
        }
	}
}

if ($limitPrcAccess -And !$ipSecuritySetInTemplateParams) {
    #ip security is not set in parameters file and we will add it here (due to configuration of PRC SCWDP packages in SC 8.2.*-9.0.1 - we can really set only one IP allowed for PRC, which shall be 127.0.0.1 to allow KeepAlive and startup app init work correctly). Word of warning though - this means, that CM package will be deployed _initially_ with same limitation, so you shall ensure that you are deploying web.config with your own ipSecurity as well
    $additionalParams.Add($clientIpString, "127.0.0.1");
    $additionalParams.Add($clientMaskString, "255.255.255.255");
}

Write-Verbose "Do we need to generate SAS? $GenerateSas"
foreach($key in $additionalParams.keys)
{
    $message = '{0} is {1}' -f $key, $additionalParams[$key]
    Write-Verbose $message
}

if ($DeploymentType -eq "infra") {
    $additionalParams.Set_Item('deploymentId', $RgName);
} else {
    #now, tricky part = get license.xml content
    if ($licenseLocation -ne "none") {
        #license file is not defined in template
        if ($licenseLocation -eq "inline") {
            #license is added to VSTS release settings
            $licenseFileContent = Get-VstsInput -Name inlineLicense -Require
        }
        if ($licenseLocation -eq "filesystem") {
                # read the contents of your Sitecore license file
                $licenseFsPath = Get-VstsInput -Name pathToLicense -Require
                $licenseFileContent = Get-Content -Raw -Encoding UTF8 -Path $licenseFsPath | Out-String;
        }
        if ($licenseLocation -eq "url") {
            #read license from URL
            $licenseUriInput = Get-VstsInput -Name urlToLicense -Require
            if ($GenerateSas) {
                #trying to generate SAS
                $licenseUri = TryGenerateSas -maybeStorageUri $licenseUriInput
            } else {
                $licenseUri = $licenseUriInput
            }
            Write-Verbose "We are going to download license from $licenseUri"
            $wc = New-Object System.Net.WebClient
            $wc.Encoding = [System.Text.Encoding]::UTF8
            $licenseFileContent =  $wc.DownloadString($licenseUri)
        }
        #we shall update ARM template parameters only in case it is defined on VSTS level
        $additionalParams.Set_Item('licenseXml', $licenseFileContent);
    }
}

#endregion

try {

    Write-Host "Check if resource group already exists..."
    $notPresent = Get-AzureRmResourceGroup -Name $RgName -ev notPresent -ea 0;

    if (!$notPresent)
    {
        if ($DeploymentType -ne "infra")
        {
            #if it is not an infra deployment - than we shall throw error
            throw "Resource group is not present, exiting"
        }
        New-AzureRmResourceGroup -Name $RgName -Location $location;
    }

    Write-Verbose "Starting ARM deployment...";

    if ($DeploymentType -eq "infra") {
        $deploymentName = "sitecore-infra"
        New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $RgName -TemplateFile $ArmTemplatePath -TemplateParameterObject $additionalParams;
    } else {
        #deployment name is used to generate login to SQL as well - so for msdeploy and redeploy it shall be equal
        $deploymentName = "sitecore-msdeploy"
        # Fetch output parameters from Sitecore ARM deployment as authoritative source for the rest of web deploy params
        $sitecoreDeployment = Get-AzureRmResourceGroupDeployment -ResourceGroupName $RgName -Name "sitecore-infra"
        $sitecoreDeploymentOutput = $sitecoreDeployment.Outputs
        $sitecoreDeploymentOutputAsJson =  ConvertTo-Json $sitecoreDeploymentOutput -Depth 5
        $sitecoreDeploymentOutputAsHashTable = ConvertPSObjectToHashtable $(ConvertFrom-Json $sitecoreDeploymentOutputAsJson)

        New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $RgName -TemplateFile $ArmTemplatePath -TemplateParameterObject $additionalParams -provisioningOutput $sitecoreDeploymentOutputAsHashTable;
    }

    LimitAccessToInstance -rgName $RgName -instanceName $instanceNameRep -instanceRole "rep" -limitAccessToInstanceAsString $limitRepAccessInput -ipMaskCollectionUserInput $ipList;
    Write-Host "Deployment Complete.";
}
catch {
    Write-Error $_.Exception.Message
    Break
}
