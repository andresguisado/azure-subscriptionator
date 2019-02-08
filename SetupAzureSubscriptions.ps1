$subscriptionOfferTypeProduction = 'MS-AZR-0017P'
$subscriptionOfferTypeDevTest = 'MS-AZR-0148P' #https://azure.microsoft.com/en-us/offers/ms-azr-0148p/

# $scriptPath = Split-Path -parent $PSCommandPath
# $AzPath = Join-Path $scriptPath "modules\az\1.0.1\Az.psd1"
# if (!(Get-Module Az.Resources)){
#     Import-Module -Name $AzPath
# }

# $AzureRMBlueprintPath = Join-Path $scriptPath "modules\manage-azurermblueprint.2.0.0\Manage-AzureRMBlueprint.ps1"
# #if (!(Get-Module AzureRM.Blueprint)){
# #    Import-Module -Name $AzureRMBlueprintPath
# #}

# $AzSubscriptionPath = Join-Path $scriptPath "modules\az.subscription.0.7.1-preview\Az.Subscription.psd1"
# if (!(Get-Module Az.Subscription)){
#     Import-Module -Name $AzSubscriptionPath
# }

function Connect-Context {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $TenantId
    )

    $selectedTenantId = Get-AzTenant |?{$_.Id -eq $TenantId } | %{$_.Id}

    if ($selectedTenantId){
        $result = Select-AzSubscription -TenantId $selectedTenantId
        if ($result.Tenant.Id -eq $selectedTenantId){
            $ManagementGroupName = Get-AzManagementGroup | ?{ $_.Name -eq $_.TenantId } | %{ $_.TenantId}
            $EnrollmentAccountId = Get-AzEnrollmentAccount | %{$_.ObjectId}
        }
    }

    @{'TenantId'=$TenantId;'EnrollmentAccountId'=$EnrollmentAccountId;'ManagementGroupName'=$ManagementGroupName;}
}

function Get-ClonedObject {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [hashtable] $DeepCopyObject
    )

    $memStream = new-object IO.MemoryStream
    $formatter = new-object Runtime.Serialization.Formatters.Binary.BinaryFormatter
    $formatter.Serialize($memStream,$DeepCopyObject)
    $memStream.Position=0
    $formatter.Deserialize($memStream)
}

function Get-TopologicalSort {
  param(
      [Parameter(Mandatory = $true, Position = 0)]
      [hashtable] $edgeList
  )

  # Make sure we can use HashSet
  Add-Type -AssemblyName System.Core

  # Clone it so as to not alter original
  $currentEdgeList = [hashtable] (Get-ClonedObject $edgeList)

  # algorithm from http://en.wikipedia.org/wiki/Topological_sorting#Algorithms
  $topologicallySortedElements = New-Object System.Collections.ArrayList
  $setOfAllNodesWithNoIncomingEdges = New-Object System.Collections.Queue

  $fasterEdgeList = @{}

  # Keep track of all nodes in case they put it in as an edge destination but not source
  $allNodes = New-Object -TypeName System.Collections.Generic.HashSet[object] -ArgumentList (,[object[]] $currentEdgeList.Keys)

  foreach($currentNode in $currentEdgeList.Keys) {
      $currentDestinationNodes = [array] $currentEdgeList[$currentNode]
      if($currentDestinationNodes.Length -eq 0) {
          $setOfAllNodesWithNoIncomingEdges.Enqueue($currentNode)
      }

      foreach($currentDestinationNode in $currentDestinationNodes) {
          if(!$allNodes.Contains($currentDestinationNode)) {
              [void] $allNodes.Add($currentDestinationNode)
          }
      }

      # Take this time to convert them to a HashSet for faster operation
      $currentDestinationNodes = New-Object -TypeName System.Collections.Generic.HashSet[object] -ArgumentList (,[object[]] $currentDestinationNodes )
      [void] $fasterEdgeList.Add($currentNode, $currentDestinationNodes)        
  }

  # Now let's reconcile by adding empty dependencies for source nodes they didn't tell us about
  foreach($currentNode in $allNodes) {
      if(!$currentEdgeList.ContainsKey($currentNode)) {
          [void] $currentEdgeList.Add($currentNode, (New-Object -TypeName System.Collections.Generic.HashSet[object]))
          $setOfAllNodesWithNoIncomingEdges.Enqueue($currentNode)
      }
  }

  $currentEdgeList = $fasterEdgeList

  while($setOfAllNodesWithNoIncomingEdges.Count -gt 0) {        
      $currentNode = $setOfAllNodesWithNoIncomingEdges.Dequeue()
      [void] $currentEdgeList.Remove($currentNode)
      [void] $topologicallySortedElements.Add($currentNode)

      foreach($currentEdgeSourceNode in $currentEdgeList.Keys) {
          $currentNodeDestinations = $currentEdgeList[$currentEdgeSourceNode]
          if($currentNodeDestinations.Contains($currentNode)) {
              [void] $currentNodeDestinations.Remove($currentNode)

              if($currentNodeDestinations.Count -eq 0) {
                  [void] $setOfAllNodesWithNoIncomingEdges.Enqueue($currentEdgeSourceNode)
              }                
          }
      }
  }

  if($currentEdgeList.Count -gt 0) {
      throw 'Graph has at least one cycle!'
  }

  return $topologicallySortedElements
}

function Get-TopologicalSortedAzAdGroups {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $AzureRmAdGroups
    )

    if (!$AzureRmAdGroups){
        return @()
    }

    $azureRmAdGroupNames = @{} 
    $AzureRmAdGroups | %{
        $value = $_.DisplayName
        $_.Members | %{
            $key = $_.DisplayName
            $azureRmAdGroupNames[$key]+=@($value)
        }
        $azureRmAdGroupNames[$value]+=@()
    }
    $topologicalSortedAzureRmAdGroupNames = @(Get-TopologicalSort -edgeList $azureRmAdGroupNames | ?{$_ -and $AzureRmAdGroups.DisplayName.Contains($_)})
    [array]::Reverse($topologicalSortedAzureRmAdGroupNames)
    $topologicalSortedAzureRmAdGroups = @()

    $topologicalSortedAzureRmAdGroupNames | %{
        $adGroupName = $_
        $topologicalSortedAzureRmAdGroups += $AzureRmAdGroups |? {$_.DisplayName -eq $adGroupName}
    }

    $topologicalSortedAzureRmAdGroups
}

Function Set-DscAdGroup {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $DesiredState,
        [Parameter(Mandatory = $false, Position = 1)]
        $DeleteUnknownAdGroupMembers = $false,
        [Parameter(Mandatory = $false, Position = 2)]
        $DeleteUnknownAdGroups = $false
    )

    $AdGroups = $DesiredState.AdGroups

    $currentAdGroups = @(Get-AzADGroup | ?{ $_.ObjectType -eq 'Group'} | %{
        $id = $_.Id
        $displayName = $_.DisplayName
        $members = @(Get-AzADGroupMember -GroupObjectId $id | ?{ $_.ObjectType -eq 'Group'} | %{
            @{'Id'=$_.Id;'DisplayName'=$_.DisplayName;}    
        })

        @{'Id'=$id;'DisplayName'=$displayName;'Members'=$members;}
    })

    $updateAdGroups = @($currentAdGroups | ?{$AdGroups -and $AdGroups.DisplayName.Contains($_.DisplayName)})

    $createAdGroups = @($AdGroups | ?{!($updateAdGroups -and $updateAdGroups.DisplayName.Contains($_.DisplayName))} | %{
        $displayName = $_.DisplayName
        $members = @($_.Members | %{
            @{'Id'='';'DisplayName'=$_;}    
        })
        @{'Id'=$id;'DisplayName'=$displayName;'Members'=$members;}
    })

    $desiredAdGroups = @()
    $desiredAdGroups += $createAdGroups
    $desiredAdGroups += $updateAdGroups

    $desiredAdGroupResults = @(Get-TopologicalSortedAzAdGroups -AzureRmAdGroups $desiredAdGroups) | %{
        $objectId = $_.Id
        $displayName = $_.DisplayName
        $members = @($_.Members)

        if ($createAdGroups -and $createAdGroups.DisplayName.Contains($displayName)){
            $mailNickName = [guid]::NewGuid().Guid
            Write-Host "New-AzADGroup -DisplayName '$displayName' -MailNickName '$mailNickName'"
            $currentAdGroup = New-AzADGroup -DisplayName $displayName -MailNickName $mailNickName
            $objectId = $currentAdGroup.Id
            
            $currentMembers = $members | %{
                $memberObjectId = Get-AzADGroup -Searchstring $memberDisplayName | ?{ $_.DisplayName -eq $memberDisplayName } | %{ $_.Id }
                Write-Host "Add-AzADGroupMember -TargetGroupObjectId '$($objectId)' -MemberObjectId '$memberObjectId'"
                $result = Add-AzADGroupMember -TargetGroupObjectId $objectId -MemberObjectId $memberObjectId
                @{'Id'=$result.Id;'DisplayName'=$memberDisplayName;}
            }

            $_.Id = $objectId
            $_.Members = $currentMembers
            $_
        } elseif ($updateAdGroups -and $updateAdGroups.DisplayName.Contains($displayName)) {
            $desiredAdGroup = $AdGroups | ?{$_.DisplayName -eq $displayName}
            if ($desiredAdGroup)
            {
                $desiredMembers = @($desiredAdGroup.Members)

                $currentMembers = @($desiredMembers |?{!$members -or !$members.DisplayName.Contains($_.DisplayName) } | %{
                    #add
                    $memberDisplayName = $_

                    $memberObjectId = Get-AzADGroup -Searchstring $memberDisplayName | ?{ $_.DisplayName -eq $memberDisplayName } | %{ $_.Id }
                    Write-Host "Add-AzADGroupMember -TargetGroupObjectId '$($objectId)' -MemberObjectId '$memberObjectId'"
                    $result = Add-AzADGroupMember -TargetGroupObjectId $objectId -MemberObjectId $memberObjectId
                
                    @{'Id'=$result.Id;'DisplayName'=$memberDisplayName;} 
                })

                $currentMembers += @($members |?{$desiredMembers -or $desiredMembers.Contains($_.DisplayName) }) | %{
                    #update
                    $_
                }

                if ($DeleteUnknownAdGroupMembers) {
                    @($members |?{!$desiredMembers -or !$desiredMembers.Contains($_.DisplayName) }) | %{
                        $memberObjectId = $_.Id
                        
                        #delete
                        Write-Host "Remove-AzADGroupMember -GroupObjectId '$($currentAdGroup.Id)' -MemberObjectId '$memberObjectId'"
                        $result = Remove-AzADGroupMember -GroupObjectId $currentAdGroup.Id -MemberObjectId $memberObjectId
                    }
                }
                              
                $_.Members = $currentMembers
                $_
            }
        }
    }

    if ($DeleteUnknownAdGroups) {
        $deleteAdGroupObjectIds = Get-TopologicalSortedAzAdGroups -AzureRmAdGroups @($currentAdGroups | ?{!($AdGroups -and $AdGroups.DisplayName.Contains($_.DisplayName))}) | %{$_.Id}
        if ($deleteAdGroupObjectIds) {
            [array]::Reverse($deleteAdGroupObjectIds)
            $deleteAdGroupObjectIds | %{
                Write-Host "Remove-AzADGroup -ObjectId '$_' -PassThru:`$false -Force"
                $result = Remove-AzADGroup -ObjectId $_ -PassThru:$false -Force
            }
        }
    }

    $desiredAdGroupResults
}

function Get-TopologicalSortedAzManagementGroups {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $AzureRmManagementGroups
    )

    if (!$AzureRmManagementGroups){
        return @()
    }
    $azureRmManagementGroupNames = @{} 
    $AzureRmManagementGroups | %{
        $key = $_.Name
        $value = $_.ParentId
        $azureRmManagementGroupNames[$key]=$value
    }
    $azureRmManagementGroupNames = Get-TopologicalSort -edgeList $azureRmManagementGroupNames | ?{$AzureRmManagementGroups.Name.Contains($_)}
  
    $topologicalSortedAzureRmManagementGroups = @()

    $azureRmManagementGroupNames | %{
        $managementGroupName = $_
        $topologicalSortedAzureRmManagementGroups += $AzureRmManagementGroups |? {$_.Name -eq $managementGroupName}
    }

    $topologicalSortedAzureRmManagementGroups
}

Function Delete-DscRoleDefinition {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $Name,
        [Parameter(Mandatory = $false, Position = 1)]
        $DeleteRecursively = $true
    )

    Write-Host "Remove-AzRoleDefinition -Name '$Name' -Force"
    $result = Remove-AzRoleDefinition -Name $Name -Force
}

Function Delete-DscPolicySetDefinition {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $Name,
        [Parameter(Mandatory = $true, Position = 1)]
        $ManagementGroupName,
        [Parameter(Mandatory = $false, Position = 2)]
        $DeleteRecursively = $true
    )

    Write-Host "Remove-AzPolicySetDefinition -ManagementGroupName '$ManagementGroupName' -Name '$Name' -Force"
    $result = Remove-AzPolicySetDefinition -ManagementGroupName $ManagementGroupName -Name $Name -Force
}

Function Delete-DscPolicyDefinition {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $Name,
        [Parameter(Mandatory = $true, Position = 1)]
        $ManagementGroupName,
        [Parameter(Mandatory = $false, Position = 2)]
        $DeleteRecursively = $true
    )

    Write-Host "Remove-AzPolicyDefinition -ManagementGroupName '$ManagementGroupName' -Name '$Name' -Force"
    $result = Remove-AzPolicyDefinition -ManagementGroupName $ManagementGroupName -Name $Name -Force
}

Function Delete-DscManagementGroup {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $ManagementGroupName,
        [Parameter(Mandatory = $false, Position = 1)]
        $DeleteRecursively = $true
    )
    
    if ($DeleteRecursively){
        $ManagementGroup = Get-AzManagementGroup -GroupName $ManagementGroupName -Expand
        $ManagementGroup.Children | %{
            $type = $_.Type
            if ($type -eq '/providers/Microsoft.Management/managementGroups'){
                Update-AzManagementGroup -GroupName $_.Name -ParentId $ManagementGroup.ParentId
            } elseif ($type -eq '/subscriptions') {
                New-AzManagementGroupSubscription -GroupName $ManagementGroup.ParentName -SubscriptionId $_.Name
            }
        }
    }

    Write-Host "Remove-AzManagementGroup -GroupName '$ManagementGroupName'"
    $result = Remove-AzManagementGroup -GroupName $ManagementGroupName
}

Function Set-DscManagementGroup {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $DesiredState,
        [Parameter(Mandatory = $false, Position = 1)]
        $DeleteUnknownManagementGroups = $false
    )

    $ManagementGroups = $DesiredState.ManagementGroups

    $parentIdPrefix = '/providers/Microsoft.Management/managementGroups/'

    $ManagementGroups = $ManagementGroups | %{
        if (!$_.ParentId.Contains('/')){
            $_.ParentId = $parentIdPrefix + $_.ParentId
        }
        $_
    }

    $currentManagementGroups = @(Get-AzManagementGroup | %{
        $name = $_.Name
        $displayName = $_.DisplayName
        $parentId = (Get-AzManagementGroup -GroupName $name -Expand).ParentId
        #if ($parentId){
        #    $parentId = $parentId.TrimStart($parentIdPrefix)
        #}
        @{'Name'=$name;'DisplayName'=$displayName;'ParentId'=$parentId;}
    })

    $rootManagementGroupName = $currentManagementGroups | ?{$null -eq $_.ParentId} | %{$_.Name}
    $updateManagementGroups = @($currentManagementGroups | ?{$null -ne $_.ParentId -and ($ManagementGroups -and $ManagementGroups.Name.Contains($_.Name))})
    
    $createManagementGroups = @($ManagementGroups | ?{!($updateManagementGroups -and $updateManagementGroups.Name.Contains($_.Name))} | %{
        $name = $_.Name
        $displayName = $_.DisplayName
        $parentId = $_.ParentId
        if ($parentId){
            $parentId = $parentId.TrimStart($parentIdPrefix)
        } 
        
        if (!$parentId) {
            #Non specified parent id means root management group is parent
            $parentId = $rootManagementGroupName
        }
        @{'Name'=$name;'DisplayName'=$displayName;'ParentId'=$parentId;}
    })
    
    $desiredManagementGroups = @()
    $desiredManagementGroups += $createManagementGroups
    $desiredManagementGroups += $updateManagementGroups

    $desiredManagementGroupResults = @(Get-TopologicalSortedAzManagementGroups -AzureRmManagementGroups $desiredManagementGroups) | %{
        $name = $_.Name
        $displayName = $_.DisplayName
        $parentId = $_.ParentId
        if ($parentId){
            $parentId = $parentId.TrimStart($parentIdPrefix)
        } 
        if (!$parentId) {
            #Non specified parent id means root management group is parent
            $parentId = $rootManagementGroupName
        }

        if ($createManagementGroups -and $createManagementGroups.Name.Contains($name)){
            Write-Host "New-AzManagementGroup -GroupName '$name' -DisplayName '$displayName' -ParentId '$($parentIdPrefix)$($parentId)'"
            $result = New-AzManagementGroup -GroupName $name -DisplayName $displayName -ParentId "$($parentIdPrefix)$($parentId)"
            $_
        } elseif ($updateManagementGroups -and $updateManagementGroups.Name.Contains($name)) {
            $desiredManagementGroup = $ManagementGroups | ?{$_.Name -eq $name}
            if ($desiredManagementGroup)
            {
                $desiredDisplayName = $desiredManagementGroup.DisplayName
                $desiredParentId = $desiredManagementGroup.ParentId
                if ($desiredParentId){
                    $desiredParentId = $desiredParentId.TrimStart($parentIdPrefix)
                } 
                if (!$desiredParentId) {
                    #Non specified parent id means root management group is parent
                    $desiredParentId = $rootManagementGroupName
                }
                if ($desiredDisplayName -ne $displayName -or $desiredParentId -ne $parentId) {
                    Write-Host "Update-AzManagementGroup -GroupName '$name' -DisplayName '$desiredDisplayName' -ParentId '$($parentIdPrefix)$($desiredParentId)'"
                    $result = Update-AzManagementGroup -GroupName $name -DisplayName $desiredDisplayName -ParentId "$($parentIdPrefix)$($desiredParentId)"
                }
                $_
            }
        } 
    }

    if ($DeleteUnknownManagementGroups) {
        $deleteManagementGroupNames = Get-TopologicalSortedAzManagementGroups -AzureRmManagementGroups @($currentManagementGroups | ?{$null -ne $_.ParentId -and !($ManagementGroups -and $ManagementGroups.Name.Contains($_.Name))}) | %{$_.Name}
        
        if ($deleteManagementGroupNames) {
            [array]::Reverse($deleteManagementGroupNames)
            $deleteManagementGroupNames | %{
                Delete-DscManagementGroup -ManagementGroupName $_
            }
        }
    }

    $desiredManagementGroupResults
}

function Get-SubscriptionForManagementGroupHiearchy {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $ManagementGroupHiearchy
    )

    $subscriptions = @()
    $subscriptions += @($ManagementGroupHiearchy.Children | ?{$_.Type -eq '/subscriptions'} | %{$_.Id})
    $subscriptions += @($ManagementGroupHiearchy.Children | ?{$_.Type -eq '/providers/Microsoft.Management/managementGroups'} | %{ Get-SubscriptionForManagementGroupHiearchy -ManagementGroupHiearchy $_})
    $subscriptions
}

function Get-SubscriptionForTenants {
    @(Get-AzSubscription | %{"/subscriptions/$($_.Id)"})
}

Function Set-DscSubscription {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $DesiredState,
        [Parameter(Mandatory = $false, Position = 1)]
        $CancelUnknownSubscriptions = $false
    )

    
    #Create subscription and assign owner
    #https://docs.microsoft.com/en-us/azure/azure-resource-manager/programmatically-create-subscription?tabs=azure-powershell
    #https://docs.microsoft.com/en-us/powershell/module/azurerm.subscription/new-azurermsubscription?view=azurermps-6.10.0
    #Set-AzureSubscription
    #Get-AzureSubscription

    #Add subscription to management group
    #$ManagementGroupName = "ProductionHub1LOB2CICDBYOP"
    #$SubscriptionId = "87c5bf6c-dcba-43d2-bf32-6f16f072b472"
    #New-AzManagementGroupSubscription -GroupName $ManagementGroupName -SubscriptionId $SubscriptionId

    Write-Host "Set-DscSubscription is not implemented yet"
}

Function Set-DscBlueprintDefinition {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $ManagementGroups,
        [Parameter(Mandatory = $false, Position = 1)]
        $DeleteUnknownBlueprints = $false
    )

    #Create blue print at root, then all management groups can apply them at any level
    #Resource Manager templates
    #https://www.youtube.com/watch?v=SMORUIPhKd8&feature=youtu.be
    #BluePrintDefinitions

    Write-Host "Set-DscBlueprintDefinition is not implemented yet"
}

Function Set-DscRoleDefinition {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $RoleDefinitionPath,
        [Parameter(Mandatory = $false, Position = 1)]
        $DeleteUnknownRoleDefinition = $false
    )

    $RoleDefinitions = Get-ChildItem -Path $RoleDefinitionPath -Filter *.json | %{
        $name = $_.Basename
        $inputFileObject = [System.IO.File]::ReadAllLines($_.FullName) | ConvertFrom-Json
        if ($inputFileObject.IsCustom){
            $assignableScopes = @()

            #https://feedback.azure.com/forums/911473-azure-management-groups/suggestions/34391878-allow-custom-rbac-definitions-at-the-management-gr
            #Currently cannot be set to the root scope ("/") or a management group scope

            $inputFileObject.AssignableScopes | %{
                if (!$_){

                }
                if ($_ -eq '/') {
                    $assignableScopes += @(Get-SubscriptionForTenants)
                } elseif ($_.StartsWith('/providers/Microsoft.Management/managementGroups/')) {
                    $managementGroupHiearchy = Get-AzManagementGroup -GroupName $ManagementGroup.TrimStart('/providers/Microsoft.Management/managementGroups/') -Expand -Recurse
                    $assignableScopes += @(Get-SubscriptionForManagementGroupHiearchy -ManagementGroupHiearchy $managementGroupHiearchy)
                } else {
                    $assignableScopes += @($_)
                }
            } 

            $inputFileObject.AssignableScopes = $assignableScopes

            $inputFile = ConvertTo-Json $inputFileObject -Depth 99

            @{'Name'=$name;'InputFile'=$inputFile;}        
        }
    }

    #hack - cache issues hence the %{try{Get-AzRoleDefinition -Id $_.Id}catch{}}
    $currentRoleDefinitions = @(Get-AzRoleDefinition -Custom | %{try{$r=Get-AzRoleDefinition -Id $_.Id -ErrorAction Stop;$r}catch{}} | %{
        $name = $_.Name
        $inputFile = ConvertTo-Json $_ -Depth 99
        @{'Name'=$name;'InputFile'=$inputFile;}
    })

    #hack start - cache issues hence the double createRole check
    $updateRoleDefinitions = @($currentRoleDefinitions | ?{$RoleDefinitions -and $RoleDefinitions.Name.Contains($_.Name)})
    $createRoleDefinitions = @($RoleDefinitions | ?{!($updateRoleDefinitions -and $updateRoleDefinitions.Name.Contains($_.Name))})
    $currentRoleDefinitions += @($createRoleDefinitions | %{try{$r=Get-AzRoleDefinition -Name $_.Name -ErrorAction Stop;$r}catch{}} | %{
        $name = $_.Name
        $inputFile = ConvertTo-Json $_ -Depth 99
        @{'Name'=$name;'InputFile'=$inputFile;}
    })
    #hack stop - cache issues hence the double createRole check
    
    $updateRoleDefinitions = @($currentRoleDefinitions | ?{$RoleDefinitions -and $RoleDefinitions.Name.Contains($_.Name)})
    $createRoleDefinitions = @($RoleDefinitions | ?{!($updateRoleDefinitions -and $updateRoleDefinitions.Name.Contains($_.Name))})

    $desiredRoleDefinitions = @()
    $desiredRoleDefinitions += $createRoleDefinitions
    $desiredRoleDefinitions += $updateRoleDefinitions

    $desiredRoleDefinitionResults = $desiredRoleDefinitions | %{
        $name = $_.Name
        $inputFile = $_.InputFile

        if ($createRoleDefinitions -and $createRoleDefinitions.Name.Contains($name)){
            Write-Host @"
`$inputFile=@'
$inputFile
'@                    
New-AzRoleDefinition -Role ([Microsoft.Azure.Commands.Resources.Models.Authorization.PSRoleDefinition](`$inputFile | ConvertFrom-Json))
"@
            $result = New-AzRoleDefinition -Role ([Microsoft.Azure.Commands.Resources.Models.Authorization.PSRoleDefinition]($inputFile | ConvertFrom-Json))
            $_
        } elseif ($updateRoleDefinitions -and $updateRoleDefinitions.Name.Contains($name)) {
            $desiredRoleDefinition = $RoleDefinitions | ?{$_.Name -eq $name}
            if ($desiredRoleDefinition)
            {
                $desiredInputFileObject = $desiredRoleDefinition.InputFile | ConvertFrom-Json 
                $r = $desiredInputFileObject | Add-Member -MemberType noteProperty -name 'Id' -Value (($inputFile | ConvertFrom-Json).Id) 
                $desiredInputFile = ConvertTo-Json ([Microsoft.Azure.Commands.Resources.Models.Authorization.PSRoleDefinition]$desiredInputFileObject) -Depth 99
                
                if ($desiredInputFile -ne $inputFile) {
                    Write-Host @"
`$desiredInputFile=@'
$desiredInputFile
'@
`$inputFile=@'
$inputFile
'@
Set-AzRoleDefinition -Role ([Microsoft.Azure.Commands.Resources.Models.Authorization.PSRoleDefinition](`$desiredInputFile | ConvertFrom-Json))
"@
                    $result = Set-AzRoleDefinition -Role ([Microsoft.Azure.Commands.Resources.Models.Authorization.PSRoleDefinition]($desiredInputFile | ConvertFrom-Json))                }
                $_
            }
        }
    }

    if ($DeleteUnknownRoleDefinition) {
        $deleteRoleDefinitionNames = @($currentRoleDefinitions | ?{!($RoleDefinitions -and $RoleDefinitions.Name.Contains($_.Name))}) | %{$_.Name}
        $deleteRoleDefinitionNames | %{
            Delete-DscPolicyDefinition -Name $_
        }
    }

    $desiredRoleDefinitionResults
}

Function Set-DscPolicyDefinition {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $PolicyDefinitionPath,
        [Parameter(Mandatory = $true, Position = 1)]
        $ManagementGroupName,
        [Parameter(Mandatory = $false, Position = 2)]
        $DeleteUnknownPolicyDefinition = $false
    )

    $PolicyDefinitions = Get-ChildItem -Path $PolicyDefinitionPath | ?{ $_.PSIsContainer -and (Test-Path -Path (Join-Path $_.FullName 'azurepolicy.json'))} | %{
        $inputFileObject = [System.IO.File]::ReadAllLines((Join-Path $_.FullName 'azurepolicy.json')) | ConvertFrom-Json
        if ($inputFileObject.Properties.policyType -ne 'BuiltIn'){
            $name = $inputFileObject.name
            if (!$name){
                $name = $_.Basename
            }
            $description = $inputFileObject.properties.description
            $displayName = $inputFileObject.properties.displayName
            $metadata = ConvertTo-Json $inputFileObject.properties.metadata -Depth 99
            $policy = ConvertTo-Json $inputFileObject.properties.policyRule -Depth 99
            $parameter = ConvertTo-Json $inputFileObject.properties.parameters -Depth 99
 
            @{'Name'=$name;'Description'=$description;'DisplayName'=$displayName;'Metadata'=$metadata;'Policy'=$policy;'Parameter'=$parameter;}        
        }
    }

    #"Custom" flag does not seem to work hence filtering
    $currentPolicyDefinitions = @(Get-AzPolicyDefinition -Custom -ManagementGroupName $ManagementGroupName | ?{$_.Properties.policyType -ne 'BuiltIn'} | %{
        $name = $_.Name
        $description = $_.properties.description
        $displayName = $_.properties.displayName
        $metadata = ConvertTo-Json $_.properties.metadata -Depth 99
        $policy = ConvertTo-Json $_.properties.policyRule -Depth 99
        $parameter = ConvertTo-Json $_.properties.parameters -Depth 99

        @{'Name'=$name;'Description'=$description;'DisplayName'=$displayName;'Metadata'=$metadata;'Policy'=$policy;'Parameter'=$parameter;}
    })

    $updatePolicyDefinitions = @($currentPolicyDefinitions | ?{$PolicyDefinitions -and $PolicyDefinitions.Name.Contains($_.Name)})
    $createPolicyDefinitions = @($PolicyDefinitions | ?{!($updatePolicyDefinitions -and $updatePolicyDefinitions.Name.Contains($_.Name))})

    $desiredPolicyDefinitions = @()
    $desiredPolicyDefinitions += $createPolicyDefinitions
    $desiredPolicyDefinitions += $updatePolicyDefinitions

    $desiredPolicyDefinitionResults = $desiredPolicyDefinitions | %{
        $name = $_.Name
        $description = $_.Description
        $displayName = $_.DisplayName
        $metadata = $_.Metadata
        $policy = $_.Policy
        $parameter = $_.Parameter

        if ($createPolicyDefinitions -and $createPolicyDefinitions.Name.Contains($name)){
            Write-Host @"
`$metadata=@'
$metadata
'@
`$policy=@'
$policy
'@
`$parameter=@'
$parameter
'@
New-AzPolicyDefinition -ManagementGroupName '$ManagementGroupName' -Name '$name' -DisplayName '$displayName' -Description '$description' -Metadata `$metadata -Policy `$policy -Parameter `$parameter
"@
            $result = New-AzPolicyDefinition -ManagementGroupName $ManagementGroupName -Name $name -DisplayName $displayName -Description $description -Metadata $metadata -Policy $policy -Parameter $parameter
            $_
        } elseif ($updatePolicyDefinitions -and $updatePolicyDefinitions.Name.Contains($name)) {
            $desiredPolicyDefinition = $PolicyDefinitions | ?{$_.Name -eq $name}
            if ($desiredPolicyDefinition)
            {
                $desiredDescription = $desiredPolicyDefinition.Description
                $desiredDisplayName = $desiredPolicyDefinition.DisplayName
                $desiredMetadata = $desiredPolicyDefinition.Metadata
                $desiredPolicy = $desiredPolicyDefinition.Policy
                $desiredParameter = $desiredPolicyDefinition.Parameter

                if ($desiredDescription -ne $description){
                    Write-Host @"
                    Desired Description:
                    $desiredDescription

                    Current Description:
                    $description
"@
                }

                if ($desiredDisplayName -ne $displayName){
                    Write-Host @"
                    Desired Display Name:
                    $desiredDisplayName

                    Actual Display Name:
                    $displayName
"@
                }

                if ($desiredMetadata -ne $metadata){
                    Write-Host @"
                    Desired Metadata:
                    $desiredMetadata

                    Actual Metadata:
                    $metadata
"@
                }     
                
                if ($desiredPolicy -ne $policy){
                    Write-Host @"
                    Desired Policy:
                    $desiredPolicy

                    Actual Policy:
                    $policy
"@
                }      
                
                if ($desiredParameter -ne $parameter){
                    Write-Host @"
                    Desired Parameters:
                    $desiredParameter

                    Actual Parameters:
                    $parameter
"@
                }
        
                if ($desiredDescription -ne $description -or $desiredDisplayName -ne $displayName -or $desiredMetadata -ne $metadata -or $desiredPolicy -ne $policy -or $desiredParameter -ne $parameter) {
                    Write-Host @"
`$metadata=@'
$desiredMetadata
'@
`$policy=@'
$desiredPolicy
'@
`$parameter=@'
$desiredParameter
'@
Set-AzPolicyDefinition -ManagementGroupName '$ManagementGroupName' -Name '$name' -DisplayName '$desiredDisplayName' -Description '$desiredDescription' -Metadata `$metadata -Policy `$policy -Parameter `$parameter
"@
                    $result = Set-AzPolicyDefinition -ManagementGroupName $ManagementGroupName -Name $name -DisplayName $desiredDisplayName -Description $desiredDescription -Metadata $desiredMetadata -Policy $desiredPolicy -Parameter $desiredParameter
                }
                $_
            }
        }
    }

    if ($DeleteUnknownPolicyDefinition) {
        $deletePolicyDefinitionNames = @($currentPolicyDefinitions | ?{!($PolicyDefinitions -and $PolicyDefinitions.Name.Contains($_.Name))}) | %{$_.Name}
        $deletePolicyDefinitionNames | %{
            Delete-DscPolicyDefinition -ManagementGroupName $ManagementGroupName -Name $_
        }
    }

    $desiredPolicyDefinitionResults
}

Function Set-DscPolicySetDefinition {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $PolicySetDefinitionPath,
        [Parameter(Mandatory = $true, Position = 1)]
        $ManagementGroupName,
        [Parameter(Mandatory = $false, Position = 2)]
        $DeleteUnknownPolicySetDefinition = $false
    )

    $PolicySetDefinitions = Get-ChildItem -Path $PolicySetDefinitionPath | ?{ $_.PSIsContainer -and (Test-Path -Path (Join-Path $_.FullName 'azurepolicyset.json'))} | %{
        $inputFileObject = [System.IO.File]::ReadAllLines((Join-Path $_.FullName 'azurepolicyset.json')) | ConvertFrom-Json
        if ($inputFileObject.Properties.policyType -ne 'BuiltIn'){
            $name = $inputFileObject.name
            if (!$name){
                $name = $_.Basename
            }
            $description = $inputFileObject.properties.description
            $displayName = $inputFileObject.properties.displayName
            $metadata = ConvertTo-Json $inputFileObject.properties.metadata -Depth 99
            $policyDefinitions = ConvertTo-Json ($inputFileObject.properties.policyDefinitions | %{
                #Dynamically created, so we have to ignore it
                $_.PSObject.Properties.Remove('policyDefinitionReferenceId')

                if (!$_.policyDefinitionId.Contains('/')){
                    $_.policyDefinitionId = "/providers/Microsoft.Management/managementgroups/$($ManagementGroupName)/providers/Microsoft.Authorization/policyDefinitions/$($_.policyDefinitionId)"
                }
                $_
            }) -Depth 99
            $parameter = ConvertTo-Json $inputFileObject.properties.parameters -Depth 99
 
            @{'Name'=$name;'Description'=$description;'DisplayName'=$displayName;'Metadata'=$metadata;'PolicyDefinitions'=$policyDefinitions;'Parameter'=$parameter;}        
        }
    }

    #"Custom" flag does not seem to work hence filtering
    $currentPolicySetDefinitions = @(Get-AzPolicySetDefinition -Custom -ManagementGroupName $ManagementGroupName | ?{$_.Properties.policyType -ne 'BuiltIn'} | %{
        $name = $_.Name
        $description = $_.properties.description
        $displayName = $_.properties.displayName
        $metadata = ConvertTo-Json $_.properties.metadata -Depth 99
        $policyDefinitions = ConvertTo-Json ($_.properties.policyDefinitions | %{
            #Dynamically created, so we have to ignore it
            $_.PSObject.Properties.Remove('policyDefinitionReferenceId')

            if (!$_.policyDefinitionId.Contains('/')){
                $_.policyDefinitionId = "/providers/Microsoft.Management/managementgroups/$($ManagementGroupName)/providers/Microsoft.Authorization/policyDefinitions/$($_.policyDefinitionId)"
            }
            $_
        }) -Depth 99
        $parameter = ConvertTo-Json $_.properties.parameters -Depth 99

        @{'Name'=$name;'Description'=$description;'DisplayName'=$displayName;'Metadata'=$metadata;'PolicyDefinitions'=$policyDefinitions;'Parameter'=$parameter;}
    })

    $updatePolicySetDefinitions = @($currentPolicySetDefinitions | ?{$PolicySetDefinitions -and $PolicySetDefinitions.Name.Contains($_.Name)})
    $createPolicySetDefinitions = @($PolicySetDefinitions | ?{!($updatePolicySetDefinitions -and $updatePolicySetDefinitions.Name.Contains($_.Name))})

    $desiredPolicySetDefinitions = @()
    $desiredPolicySetDefinitions += $createPolicySetDefinitions
    $desiredPolicySetDefinitions += $updatePolicySetDefinitions

    $desiredPolicySetDefinitionResults = $desiredPolicySetDefinitions | %{
        $name = $_.Name
        $description = $_.Description
        $displayName = $_.DisplayName
        $metadata = $_.Metadata
        $policyDefinitions = $_.PolicyDefinitions
        $parameter = $_.Parameter

        if ($createPolicySetDefinitions -and $createPolicySetDefinitions.Name.Contains($name)){
            Write-Host @"
`$metadata=@'
$metadata
'@
`$policyDefinitions=@'
$policyDefinitions
'@
`$parameter=@'
$parameter
'@
New-AzPolicySetDefinition -ManagementGroupName '$ManagementGroupName' -Name '$name' -DisplayName '$displayName' -Description '$description' -Metadata `$metadata -PolicyDefinition `$policyDefinitions -Parameter `$parameter
"@
            $result = New-AzPolicySetDefinition -ManagementGroupName $ManagementGroupName -Name $name -DisplayName $displayName -Description $description -Metadata $metadata -PolicyDefinition $policyDefinitions -Parameter $parameter
            $_
        } elseif ($updatePolicySetDefinitions -and $updatePolicySetDefinitions.Name.Contains($name)) {
            $desiredPolicySetDefinition = $PolicySetDefinitions | ?{$_.Name -eq $name}
            if ($desiredPolicySetDefinition)
            {
                $desiredDescription = $desiredPolicySetDefinition.Description
                $desiredDisplayName = $desiredPolicySetDefinition.DisplayName
                $desiredMetadata = $desiredPolicySetDefinition.Metadata
                $desiredPolicyDefinitions = $desiredPolicySetDefinition.PolicyDefinitions
                $desiredParameter = $desiredPolicySetDefinition.Parameter

                if ($desiredDescription -ne $description){
                    Write-Host @"
                    Desired Description:
                    $desiredDescription

                    Current Description:
                    $description
"@
                }

                if ($desiredDisplayName -ne $displayName){
                    Write-Host @"
                    Desired Display Name:
                    $desiredDisplayName

                    Actual Display Name:
                    $displayName
"@
                }

                if ($desiredMetadata -ne $metadata){
                    Write-Host @"
                    Desired Metadata:
                    $desiredMetadata

                    Actual Metadata:
                    $metadata
"@
                }     
                
                if ($desiredPolicyDefinitions -ne $policyDefinitions){
                    Write-Host @"
                    Desired Policy Definitions:
                    $desiredPolicyDefinitions

                    Actual Policy Definitions:
                    $policyDefinitions
"@
                }      
                
                if ($desiredParameter -ne $parameter){
                    Write-Host @"
                    Desired Parameters:
                    $desiredParameter

                    Actual Parameters:
                    $parameter
"@
                }

                if ($desiredDescription -ne $description -or $desiredDisplayName -ne $displayName -or $desiredMetadata -ne $metadata -or $desiredPolicyDefinitions -ne $policyDefinitions -or $desiredParameter -ne $parameter) {
                    Write-Host @"
`$metadata=@'
$desiredMetadata
'@
`$policyDefinitions=@'
$desiredPolicyDefinitions
'@
`$parameter=@'
$desiredParameter
'@
Set-AzPolicySetDefinition -ManagementGroupName '$ManagementGroupName' -Name '$name' -DisplayName '$desiredDisplayName' -Description '$desiredDescription' -Metadata `$metadata -PolicyDefinition `$policyDefinitions -Parameter `$parameter
"@
                    $result = Set-AzPolicySetDefinition -ManagementGroupName $ManagementGroupName -Name $name -DisplayName $desiredDisplayName -Description $desiredDescription -Metadata $desiredMetadata -PolicyDefinition $desiredPolicyDefinitions -Parameter $desiredParameter
                }
                $_
            }
        }
    }

    if ($DeleteUnknownPolicySetDefinition) {
        $deletePolicySetDefinitionNames = @($currentPolicySetDefinitions | ?{!($PolicySetDefinitions -and $PolicySetDefinitions.Name.Contains($_.Name))}) | %{$_.Name}
        $deletePolicySetDefinitionNames | %{
            Delete-DscPolicySetDefinition -ManagementGroupName $ManagementGroupName -Name $_
        }
    }

    $desiredPolicySetDefinitionResults
}

function Get-RoleAssignmentFromConfig {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $Scope,
        [Parameter(Mandatory = $true, Position = 1)]
        $ConfigItem
    )

    $roleDefinitionName = $ConfigItem.RoleDefinitionName
    $canDelegate = $ConfigItem.CanDelegate
    $objectName = $ConfigItem.ObjectName
    $objectType = $ConfigItem.ObjectType
    $objectId = ''
    
    if ($objectType -eq "Group"){
        $group = Get-AzADGroup -DisplayName $objectName
        if ($group){
            $objectId = $group.Id
        }
    } elseif ($objectType -eq "User") {
        $user = Get-AzADUser -DisplayName $objectName
        if ($user){
            $objectId = $user.Id
        }
    } elseif ($objectType -eq "Application") {
        $application = Get-AzADApplication -DisplayName $objectName
        if ($application){
            $objectId = $application.Id
        }
    }

    if ($objectId){
        @{'RoleDefinitionName'=$roleDefinitionName;'Scope'=$Scope;'CanDelegate'=$canDelegate;'ObjectId'=$objectId;}   
    }   
}

Function Set-DscRoleAssignment {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $DesiredState,
        [Parameter(Mandatory = $false, Position = 1)]
        $DeleteUnknownRoleAssignment = $false
    )

    $RootRoleAssignments = $DesiredState.RoleAssignments 
    $ManagementGroups = $DesiredState.ManagementGroups

    $RoleAssignments = $RootRoleAssignments | ?{$_} | %{
        $scope = "/"
        Get-RoleAssignmentFromConfig -Scope $scope -ConfigItem $_
    }

    $RoleAssignments += $ManagementGroups | %{
        $ManagementGroupName = $_.Name
        $_.RoleAssignments | ?{$_} | %{
            $scope = "/providers/Microsoft.Management/managementGroups/$ManagementGroupName"
            Get-RoleAssignmentFromConfig -Scope $scope -ConfigItem $_
        }  
        $_.Subscriptions | %{
            $RoleAssignmentsForSubscription = $_.RoleAssignments | ?{$_}

            if ($RoleAssignmentsForSubscription) {
                $subscriptionName = $_.Name
                $subscription = Get-AzSubscription -SubscriptionName $subscriptionName
                $subscriptionId = $subscription.Id

                $RoleAssignmentsForSubscription | %{
                    $scope = "/subscriptions/$subscriptionId"
                    Get-RoleAssignmentFromConfig -Scope $scope -ConfigItem $_
                }
            }
        }
    }

    #Only deal with role assignments against root, management groups and subscriptions. Role assignments directly to providers should be abstracted by RoleDefinition applied at management group or subscription
    $currentRoleAssignments = @(Get-AzRoleAssignment | ?{$_.Scope -eq '/' -or $_.Scope.StartsWith('/providers/Microsoft.Management/managementGroups/') -or $_.Scope.StartsWith('/subscriptions/')} %{
        $scope = $_.Scope
        $roleDefinitionName = $_.RoleDefinitionName
        $objectId = $_.ObjectId
        $canDelegate = $_.CanDelegate
        
        @{'Scope'=$scope;'RoleDefinitionName'=$roleDefinitionName;'ObjectId'=$objectId;'CanDelegate'=$canDelegate;} 
    })

    $updateRoleAssignments = @($currentRoleAssignments | %{
        $scope = $_.Scope
        $roleDefinitionName = $_.RoleDefinitionName
        $objectId = $_.ObjectId

        if ($RoleAssignments | ?{$_.Scope -eq $scope -and $_.RoleDefinitionName -eq $roleDefinitionName -and $_.ObjectId -eq $objectId}){
           $_ 
        }
    })

    $createRoleAssignments = @($RoleAssignments | %{
        $scope = $_.Scope
        $roleDefinitionName = $_.RoleDefinitionName
        $objectId = $_.ObjectId

        if (!($updateRoleAssignments | ?{$_.Scope -eq $scope -and $_.RoleDefinitionName -eq $roleDefinitionName -and $_.ObjectId -eq $objectId})){
            $_ 
         }
    })
    
    $desiredRoleAssignments = @()
    $desiredRoleAssignments += $createRoleAssignments
    $desiredRoleAssignments += $updateRoleAssignments

    $desiredRoleAssignmentResults = $desiredRoleAssignments | %{
        $scope = $_.Scope
        $roleDefinitionName = $_.RoleDefinitionName
        $objectId = $_.ObjectId
        $canDelegate = $_.CanDelegate
   
        if ($createRoleAssignments | ?{$_.Scope -eq $scope -and $_.RoleDefinitionName -eq $roleDefinitionName -and $_.ObjectId -eq $objectId}){
            Write-Host "New-AzRoleAssignment -Scope '$scope' -RoleDefinitionName '$roleDefinitionName' -ObjectId '$objectId' -AllowDelegation:`$$canDelegate "
            $result = New-AzRoleAssignment -Scope $scope -RoleDefinitionName $roleDefinitionName -ObjectId $objectId -AllowDelegation:$canDelegate
            $_
        } elseif ($updateRoleAssignments | ?{$_.Scope -eq $scope -and $_.RoleDefinitionName -eq $roleDefinitionName -and $_.ObjectId -eq $objectId}) {
            $desiredRoleAssignment = $RoleAssignments | ?{$_.Scope -eq $scope -and $_.RoleDefinitionName -eq $roleDefinitionName -and $_.ObjectId -eq $objectId}
            if ($desiredRoleAssignment)
            {
                $desiredScope = $desiredRoleAssignment.Scope
                $desiredRoleDefinitionName = $desiredRoleAssignment.RoleDefinitionName
                $desiredObjectId = $desiredRoleAssignment.ObjectId
                $desiredCanDelegate = $desiredRoleAssignment.CanDelegate
                
                if ($desiredCanDelegate -ne $canDelegate) {
                    Write-Host @"
Get-AzRoleAssignment -Scope '$desiredScope' -RoleDefinitionName '$desiredRoleDefinitionName' -ObjectId '$desiredObjectId' | 
?{`$_.Scope -eq '$desiredScope' -and `$_.RoleDefinitionName -eq '$desiredRoleDefinitionName' -and `$_.ObjectId -eq '$desiredObjectId'} |
Remove-AzRoleAssignment

New-AzRoleAssignment -Scope '$desiredScope' -RoleDefinitionName '$desiredRoleDefinitionName' -ObjectId '$desiredObjectId' -AllowDelegation:`$$desiredCanDelegate 
"@
                    #Scope and ObjectId are not honoured as filters :<
                    $result = Get-AzRoleAssignment -Scope $desiredScope -RoleDefinitionName $desiredRoleDefinitionName -ObjectId $desiredObjectId | 
                    ?{$_.Scope -eq $desiredScope -and $_.RoleDefinitionName -eq $desiredRoleDefinitionName -and $_.ObjectId -eq $desiredObjectId} |
                    Remove-AzRoleAssignment 

                    $result = New-AzRoleAssignment -Scope '$desiredScope' -RoleDefinitionName '$desiredRoleDefinitionName' -ObjectId '$desiredObjectId' -AllowDelegation:`$$desiredCanDelegate

                    $_
                }
            }
        }
    }

    if ($DeleteUnknownRoleAssignment) {
        @($currentRoleAssignments | %{
            $scope = $_.Scope
            $roleDefinitionName = $_.RoleDefinitionName
            $objectId = $_.ObjectId
    
            if (!($RoleAssignments | ?{$_.Scope -eq $scope -and $_.RoleDefinitionName -eq $roleDefinitionName -and $_.ObjectId -eq $objectId})){
                Write-Host @"
Get-AzRoleAssignment -Scope '$scope' -RoleDefinitionName '$roleDefinitionName' -ObjectId '$objectId' | 
?{`$_.Scope -eq '$scope' -and `$_.RoleDefinitionName -eq '$roleDefinitionName' -and `$_.ObjectId -eq '$objectId'} |
Remove-AzRoleAssignment
"@
                #Scope and ObjectId are not honoured as filters :<
                $result = Get-AzRoleAssignment -Scope $scope -RoleDefinitionName $roleDefinitionName -ObjectId $objectId | 
                ?{$_.Scope -eq $scope -and $_.RoleDefinitionName -eq $roleDefinitionName -and $_.ObjectId -eq $objectId} |
                Remove-AzRoleAssignment 
            }
        })
    }

    $desiredRoleAssignmentResults
}

function Get-PolicyAssignmentFromConfig {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $Scope,
        [Parameter(Mandatory = $true, Position = 1)]
        $ConfigItem
    )

    $name = $ConfigItem.Name
    $notScope = @($ConfigItem.NotScope) |? {$_}
    
    $displayName = $ConfigItem.DisplayName
    $description = $ConfigItem.Description
    $metadata = ConvertTo-Json $ConfigItem.Metadata -Depth 99
    if ([string]::IsNullOrWhitespace($metadata)){
        $metadata = ConvertTo-Json @{}
    }
    $policyDefinitionName = $ConfigItem.PolicyDefinitionName
    $policySetDefinitionName = $ConfigItem.PolicySetDefinitionName
    $policyParameter = ConvertTo-Json $ConfigItem.PolicyParameter -Depth 99
    if ([string]::IsNullOrWhitespace($policyParameter)){
        $policyParameter = ConvertTo-Json @{}
    }

    if ($ConfigItem.AssignIdentity -eq ''){
        $assignIdentity = $false
    } else {
        $assignIdentity = [System.Convert]::ToBoolean($ConfigItem.AssignIdentity) 
    }

    $location = $ConfigItem.Location

    @{'Name'=$name;'Scope'=$Scope;'NotScope'=$notScope;'DisplayName'=$displayName;'Description'=$description;'Metadata'=$metadata;'PolicyDefinitionName'=$policyDefinitionName;'PolicySetDefinitionName'=$policySetDefinitionName;'PolicyParameter'=$policyParameter;'AssignIdentity'=$assignIdentity;'Location'=$location;}   
}

Function Set-DscPolicyAssignment {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $DesiredState,
        [Parameter(Mandatory = $false, Position = 1)]
        $DeleteUnknownPolicyAssignment = $false
    )

    $RootPolicyAssignments = $DesiredState.PolicyAssignments 
    $ManagementGroups = $DesiredState.ManagementGroups

    $PolicyAssignments = $RootPolicyAssignments | ?{$_} | %{
        $scope = "/"
        Get-PolicyAssignmentFromConfig -Scope $scope -ConfigItem $_
    }

    $PolicyAssignments += $ManagementGroups | %{
        $ManagementGroupName = $_.Name
        $_.PolicyAssignments | ?{$_} | %{
            $scope = "/providers/Microsoft.Management/managementGroups/$ManagementGroupName"
            Get-PolicyAssignmentFromConfig -Scope $scope -ConfigItem $_
        }  
        $_.Subscriptions | %{
            $PolicyAssignmentsForSubscription = $_.PolicyAssignments | ?{$_}

            if ($PolicyAssignmentsForSubscription) {
                $subscriptionName = $_.Name
                $subscription = Get-AzSubscription -SubscriptionName $subscriptionName
                $subscriptionId = $subscription.Id

                $PolicyAssignmentsForSubscription | %{
                    $scope = "/subscriptions/$subscriptionId"
                    Get-PolicyAssignmentFromConfig -Scope $scope -ConfigItem $_
                }
            }
        }
    }

    $PolicyDefinitions = Get-AzPolicyDefinition

    #Only deal with policy assignments against root, management groups and subscriptions. 
    $currentPolicyAssignments = @(Get-AzPolicyAssignment |?{$_.Properties -and $_.Properties.policyDefinitionId -match '/policyDefinitions/' -and $_.Properties.Scope} | ?{$_.Properties.Scope -eq '/' -or $_.Properties.Scope.StartsWith('/providers/Microsoft.Management/managementGroups/') -or $_.Properties.Scope.StartsWith('/subscriptions/')} | %{        
        $name = $_.Name
        $scope = $_.Properties.Scope
        $notScope = @($_.Properties.NotScope) |? {$_}
        $displayName = $_.Properties.DisplayName
        $description = $_.Properties.Description
        $metadata = ConvertTo-Json $_.Properties.Metadata -Depth 99
        if ([string]::IsNullOrWhitespace($metadata)){
            $metadata = ConvertTo-Json @{}
        }
        $policyDefinitionId = $_.Properties.policyDefinitionId

        $policyDefinitionName = "" 
        if ($policyDefinitionId -and $_.Properties.policyDefinitionId -match '/policyDefinitions/') {
            $policyDefinition = $PolicyDefinitions |? {$_.PolicyDefinitionId -eq $policyDefinitionId}
            $policyDefinitionName = $policyDefinition.Name
        }

        $policySetDefinitionName = ""
       
        $policyParameter = ConvertTo-Json $_.Properties.parameters -Depth 99
        if ([string]::IsNullOrWhitespace($policyParameter)){
            $policyParameter = ConvertTo-Json @{}
        }

        if ($_.Properties.AssignIdentity -eq ''){
            $assignIdentity = $false
        } else {
            $assignIdentity = [System.Convert]::ToBoolean($_.Properties.AssignIdentity) 
        }

        $location = $_.Properties.Location
 
        @{'Name'=$name;'Scope'=$scope;'NotScope'=$notScope;'DisplayName'=$displayName;'Description'=$description;'Metadata'=$metadata;'PolicyDefinitionName'=$policyDefinitionName;'PolicySetDefinitionName'=$policySetDefinitionName;'PolicyParameter'=$policyParameter;'AssignIdentity'=$assignIdentity;'Location'=$location;}
    })

    $updatePolicyAssignments = @($currentPolicyAssignments | %{
        $name = $_.Name
        $scope = $_.Scope
        $policyDefinitionName = $_.PolicyDefinitionName 
        
        if ($PolicyAssignments | ?{$_.Name -eq $name -and $_.Scope -eq $scope -and $_.PolicyDefinitionName -eq $policyDefinitionName}){
           $_ 
        }
    })

    $createPolicyAssignments = @($PolicyAssignments | %{
        $name = $_.Name
        $scope = $_.Scope
        $policyDefinitionName = $_.PolicyDefinitionName
        
        if (!($updatePolicyAssignments | ?{$_.Name -eq $name -and $_.Scope -eq $scope -and $_.PolicyDefinitionName -eq $policyDefinitionName})){
            $_ 
         }
    })
    
    $desiredPolicyAssignments = @()
    $desiredPolicyAssignments += $createPolicyAssignments
    $desiredPolicyAssignments += $updatePolicyAssignments

    $desiredPolicyAssignmentResults = $desiredPolicyAssignments | %{
        $name = $_.Name
        $scope = $_.Scope
        $notScope = $_.NotScope
        $displayName = $_.DisplayName
        $description = $_.Description
        $metadata = $_.Metadata
        $policyDefinitionName = $_.PolicyDefinitionName
        #$policySetDefinitionName = $_.PolicySetDefinitionName
        $policyParameter = $_.PolicyParameter
        $assignIdentity = $_.AssignIdentity
        $location = $_.Location
   
        if ($createPolicyAssignments | ?{$_.Name -eq $name -and $_.Scope -eq $scope -and $_.PolicyDefinitionName -eq $policyDefinitionName}){
            #Get-AzPolicyDefinition -Name 'xxx' seems faulty :<
            Write-Host @"
`$metadata=@'
$metadata
'@
`$policyParameter=@'
$policyParameter
'@
`$notScope=@'
$(ConvertTo-Json $notScope -Depth 99)
'@ 
`$notScope = ConvertFrom-Json `$notScope 

`$assignIdentity = [System.Convert]::ToBoolean('$assignIdentity')

`$policyDefinition = Get-AzPolicyDefinition |? {`$_.Name -eq '$policyDefinitionName'}

if (!`$policyDefinition) {
    throw "Policy definition '$policyDefinitionName' does not exist"
}

if (`$policyDefinition) {
    New-AzPolicyAssignment -Name '$name' -Scope '$scope' -NotScope `$notScope -DisplayName '$displayName' -Description '$description' -Metadata `$metadata -PolicyDefinition `$policyDefinition -PolicyParameter `$policyParameter -AssignIdentity:`$assignIdentity -Location '$location' 
}
"@
            $policyDefinition = $PolicyDefinitions |? {$_.Name -eq $policyDefinitionName}

            if (!$policyDefinition) {
                throw "Policy definition '$policyDefinitionName' does not exist"
            }

            if ($policyDefinition) {
                $result = New-AzPolicyAssignment -Name $name -Scope $scope -NotScope $notScope -DisplayName $displayName -Description $description -Metadata $metadata -PolicyDefinition $policyDefinition -PolicyParameter $policyParameter -AssignIdentity:$assignIdentity -Location $location
                $_
            }
        } elseif ($updatePolicyAssignments | ?{$_.Name -eq $name -and $_.Scope -eq $scope -and $_.PolicyDefinitionName -eq $policyDefinitionName}) {
            $desiredPolicyAssignment = $PolicyAssignments | ?{$_.Name -eq $name -and $_.Scope -eq $scope -and $_.PolicyDefinitionName -eq $policyDefinitionName}
            if ($desiredPolicyAssignment)
            {
                $desiredName = $desiredPolicyAssignment.Name
                $desiredScope = $desiredPolicyAssignment.Scope
                $desiredNotScope = $desiredPolicyAssignment.NotScope
                $desiredDisplayName = $desiredPolicyAssignment.DisplayName
                $desiredDescription = $desiredPolicyAssignment.Description
                $desiredMetadata = $desiredPolicyAssignment.Metadata
                $desiredPolicyDefinitionName = $desiredPolicyAssignment.PolicyDefinitionName
                #$desiredPolicySetDefinitionName = $desiredPolicyAssignment.PolicySetDefinitionName
                $desiredPolicyParameter = $desiredPolicyAssignment.PolicyParameter
                $desiredAssignIdentity = $desiredPolicyAssignment.AssignIdentity
                $desiredLocation = $desiredPolicyAssignment.Location

                if ($desiredName -ne $name){
                    Write-Host @"
                    Desired Name:
                    $desiredName

                    Actual Name:
                    $name
"@
                }                    

                if ($desiredScope -ne $scope){
                    Write-Host @"
                    Desired Scope:
                    $desiredScope

                    Actual Scope:
                    $scope
"@
                }

                if ($desiredNotScope -ne $notScope){
                    Write-Host @"
                    Desired Not Scope:
                    $(ConvertTo-Json $desiredNotScope -Depth 99)

                    Actual Not Scope:
                    $(ConvertTo-Json $notScope -Depth 99)
"@
                }

                if ($desiredDisplayName -ne $displayName){
                    Write-Host @"
                    Desired Display Name:
                    $desiredDisplayName

                    Actual Display Name:
                    $displayName
"@
                }

                if ($desiredDescription -ne $description){
                    Write-Host @"
                    Desired Description:
                    $desiredDescription

                    Current Description:
                    $description
"@
                }

                if ($desiredMetadata -ne $metadata){
                    Write-Host @"
                    Desired Metadata:
                    $desiredMetadata

                    Actual Metadata:
                    $metadata
"@
                }     

                if ($desiredPolicyDefinitionName -ne $policyDefinitionName){
                    Write-Host @"
                    Desired Policy Definition Name:
                    $desiredPolicyDefinitionName

                    Actual Policy Definition Name:
                    $policyDefinitionName
"@
                }     

                if ($desiredPolicyParameter -ne $policyParameter){
                    Write-Host @"
                    Desired Policy Parameter:
                    $desiredPolicyParameter

                    Actual Policy Parameter:
                    $policyParameter
"@
                }     

                if ($desiredAssignIdentity -ne $assignIdentity){
                    Write-Host @"
                    Desired Assign Identity:
                    $desiredAssignIdentity

                    Actual Assign Identity:
                    $assignIdentity
"@
                }     

                if ($desiredLocation -ne $location){
                    Write-Host @"
                    Desired Location:
                    $desiredLocation

                    Actual Location:
                    $location
"@
                }

                if ($desiredName -ne $name -or $desiredScope -ne $scope -or $desiredNotScope -ne $notScope -or $desiredDisplayName -ne $displayName -or $desiredDescription -ne $description -or $desiredMetadata -ne $metadata -or $desiredPolicyDefinitionName -ne $policyDefinitionName -or $desiredPolicyParameter -ne $policyParameter -or $desiredAssignIdentity -ne $assignIdentity -or $desiredLocation -ne $location ) {
                    #Get-AzPolicyDefinition -Name 'xxx' seems faulty :<
                    Write-Host @"
`$metadata=@'
$metadata
'@
`$desiredMetadata=@'
$desiredMetadata
'@
`$policyParameter=@'
$policyParameter
'@
`$desiredPolicyParameter=@'
$desiredPolicyParameter
'@
`$notScope=@'
$(ConvertTo-Json $notScope -Depth 99)
'@ 
`$notScope = ConvertFrom-Json `$notScope 

`$desiredNotScope=@'
$(ConvertTo-Json $desiredNotScope -Depth 99)
'@ 
`$desiredNotScope = ConvertFrom-Json `$desiredNotScope

`$assignIdentity = [System.Convert]::ToBoolean('$assignIdentity')
`$desiredAssignIdentity = [System.Convert]::ToBoolean('$desiredAssignIdentity')

`$policyDefinition = Get-AzPolicyDefinition |? {`$_.Name -eq '$policyDefinitionName'}
if ('$policyDefinitionName' -eq '$desiredPolicyDefinitionName'){
    `$desiredPolicyDefinition = `$policyDefinition
} else {
    `$desiredPolicyDefinition = Get-AzPolicyDefinition |? {`$_.Name -eq '$desiredPolicyDefinitionName'}
}

if (!`$policyDefinition) {
    throw "Policy definition '$policyDefinitionName' does not exist"
}

if (!`$desiredPolicyDefinition) {
    throw "Desired policy definition '$desiredPolicyDefinitionName' does not exist"
}

if (`$policyDefinition -and `$desiredPolicyDefinition) {
    if ('$desiredName' -ne '$name' -or '$desiredScope' -ne '$scope' -or '$desiredPolicyDefinitionName' -ne '$policyDefinitionName' -or `$desiredPolicyDefinition -ne `$policyDefinition -or `$desiredPolicyParameter -ne `$policyParameter){
        Get-AzPolicyAssignment -Name '$name' -Scope '$scope' -PolicyDefinitionId `$policyDefinition.PolicyDefinitionId | ?{`$_.Name -eq '$name' -and `$_.Scope -eq '$scope' -and `$_.PolicyDefinitionId -eq `$policyDefinition.PolicyDefinitionId} | Remove-AzRoleAssignment
        New-AzPolicyAssignment -Name '$desiredName' -Scope '$desiredScope' -NotScope `$desiredNotScope -DisplayName '$desiredDisplayName' -Description '$desiredDescription' -Metadata `$desiredMetadata -PolicyDefinition `$desiredPolicyDefinition -PolicyParameter `$desiredPolicyParameter -AssignIdentity:`$desiredAssignIdentity -Location '$desiredLocation' 
    } elseif (`$desiredNotScope -ne `$notScope -or '$desiredDisplayName' -ne '$displayName' -or '$desiredDescription' -ne '$description' -or `$desiredMetadata -ne `$metadata -or `$desiredAssignIdentity -ne `$assignIdentity -or '$desiredLocation' -ne '$location') {
        Set-AzPolicyAssignment -Name '$desiredName' -Scope '$desiredScope' -NotScope `$desiredNotScope -DisplayName '$desiredDisplayName' -Description '$desiredDescription' -Metadata `$desiredMetadata -AssignIdentity:`$desiredAssignIdentity -Location '$desiredLocation' 
    }
}
"@
                    #Get-AzPolicyDefinition -Name 'xxx' seems faulty :<
                    $policyDefinition = $PolicyDefinitions |? {$_.Name -eq $policyDefinitionName}
                    if ($policyDefinitionName -eq $desiredPolicyDefinitionName){
                        $desiredPolicyDefinition = $policyDefinition
                    } else {
                        $desiredPolicyDefinition = $PolicyDefinitions |? {$_.Name -eq $desiredPolicyDefinitionName}
                    }

                    if (!$policyDefinition) {
                        throw "Policy definition '$policyDefinitionName' does not exist"
                    }

                    if (!$desiredPolicyDefinition) {
                        throw "Desired policy definition '$desiredPolicyDefinitionName' does not exist"
                    }

                    if ($policyDefinition -and $desiredPolicyDefinition) {
                        if ($desiredName -ne $name -or $desiredScope -ne $scope -or $desiredPolicyDefinitionName -ne $policyDefinitionName -or $desiredPolicyDefinition -ne $policyDefinition -or $desiredPolicyParameter -ne $policyParameter){
                            $result = Get-AzPolicyAssignment -Name $name -Scope $scope -PolicyDefinitionId $policyDefinition.PolicyDefinitionId | ?{$_.Name -eq $name -and $_.Scope -eq $scope -and $_.PolicyDefinitionId -eq $policyDefinition.PolicyDefinitionId} | Remove-AzRoleAssignment
                            $result = New-AzPolicyAssignment -Name $desiredName -Scope $desiredScope -NotScope $desiredNotScope -DisplayName $desiredDisplayName -Description $desiredDescription -Metadata $desiredMetadata -PolicyDefinition $desiredPolicyDefinition -PolicyParameter $desiredPolicyParameter -AssignIdentity:$desiredAssignIdentity -Location $desiredLocation
                            $_
                        } elseif ($desiredNotScope -ne $notScope -or $desiredDisplayName -ne $displayName -or $desiredDescription -ne $description -or $desiredMetadata -ne $metadata -or $desiredAssignIdentity -ne $assignIdentity -or $desiredLocation -ne $location) {
                            $result = Set-AzPolicyAssignment -Name $desiredName -Scope $desiredScope -NotScope $desiredNotScope -DisplayName $desiredDisplayName -Description $desiredDescription -Metadata $desiredMetadata -AssignIdentity:$desiredAssignIdentity -Location $desiredLocation 
                            $_
                        }
                    } 
                } else {
                    $_
                }
            }
        }
    }
   
    if ($DeleteUnknownPolicyAssignment) {
        @($currentPolicyAssignments | %{
            $name = $_.Name
            $scope = $_.Scope
            $policyDefinitionName = $_.PolicyDefinitionName
    
            if (!($PolicyAssignments | ?{$_.Name -eq $name -and $_.Scope -eq $scope -and $_.PolicyDefinitionName -eq $policyDefinitionName})){
                #Get-AzPolicyDefinition -Name 'xxx' seems faulty :<
                Write-Host @"
`$policyDefinition = Get-AzPolicyDefinition |? {`$_.Name -eq '$policyDefinitionName'}
if (!`$policyDefinition) {
    throw "Policy definition '$policyDefinitionName' does not exist"
}

`$policyAssignmentId = Get-AzPolicyAssignment -Name '$name' -Scope '$scope' -PolicyDefinitionId `$policyDefinition.PolicyDefinitionId | ?{`$_.Name -eq '$name' -and `$_.Properties.scope -eq '$scope' -and `$_.Properties.policyDefinitionId -eq `$policyDefinition.PolicyDefinitionId} | %{`$_.PolicyAssignmentId}
Remove-AzPolicyAssignment -Id `$policyAssignmentId
"@

                #Get-AzPolicyDefinition -Name 'xxx' seems faulty :<
                $policyDefinition = Get-AzPolicyDefinition |? {$_.Name -eq $policyDefinitionName}
                if (!$policyDefinition) {
                    throw "Policy definition '$policyDefinitionName' does not exist"
                }

                $policyAssignmentId = Get-AzPolicyAssignment -Name $name -Scope $scope -PolicyDefinitionId $policyDefinition.PolicyDefinitionId | ?{$_.Name -eq $name -and $_.Properties.scope -eq $scope -and $_.Properties.policyDefinitionId -eq $policyDefinition.PolicyDefinitionId} | %{$_.PolicyAssignmentId}
                $result = Remove-AzPolicyAssignment -Id $policyAssignmentId
            }
        })
    }

    $desiredPolicyAssignmentResults
}

Function Set-DscPolicySetAssignment {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $DesiredState,
        [Parameter(Mandatory = $false, Position = 1)]
        $DeleteUnknownPolicySetAssignment = $false
    )

    $RootPolicySetAssignments = $DesiredState.PolicySetAssignments 
    $ManagementGroups = $DesiredState.ManagementGroups

    $PolicySetAssignments = $RootPolicySetAssignments | ?{$_} | %{
        $scope = "/"
        Get-PolicyAssignmentFromConfig -Scope $scope -ConfigItem $_
    }

    $PolicySetAssignments += $ManagementGroups | %{
        $ManagementGroupName = $_.Name
        $_.PolicySetAssignments | ?{$_} | %{
            $scope = "/providers/Microsoft.Management/managementGroups/$ManagementGroupName"
            Get-PolicyAssignmentFromConfig -Scope $scope -ConfigItem $_
        }  
        $_.Subscriptions | %{
            $PolicySetAssignmentsForSubscription = $_.PolicySetAssignments | ?{$_}

            if ($PolicySetAssignmentsForSubscription) {
                $subscriptionName = $_.Name
                $subscription = Get-AzSubscription -SubscriptionName $subscriptionName
                $subscriptionId = $subscription.Id

                $PolicySetAssignmentsForSubscription | %{
                    $scope = "/subscriptions/$subscriptionId"
                    Get-PolicyAssignmentFromConfig -Scope $scope -ConfigItem $_
                }
            }
        }
    }

    $PolicySetDefinitions = Get-AzPolicySetDefinition

    #Only deal with policy set assignments against root, management groups and subscriptions. 
    $currentPolicySetAssignments = @(Get-AzPolicyAssignment |?{$_.Properties -and $_.Properties.policyDefinitionId -match '/policySetDefinitions/' -and $_.Properties.Scope} | ?{$_.Properties.Scope -eq '/' -or $_.Properties.Scope.StartsWith('/providers/Microsoft.Management/managementGroups/') -or $_.Properties.Scope.StartsWith('/subscriptions/')} | %{        
        $name = $_.Name
        $scope = $_.Properties.Scope
        $notScope = @($_.Properties.NotScope) |? {$_}
        $displayName = $_.Properties.DisplayName
        $description = $_.Properties.Description
        $metadata = ConvertTo-Json $_.Properties.Metadata -Depth 99
        if ([string]::IsNullOrWhitespace($metadata)){
            $metadata = ConvertTo-Json @{}
        }
        $policyDefinitionId = $_.Properties.policyDefinitionId

        $policyDefinitionName = "" 
        
        $policySetDefinitionName = ""
        if ($policyDefinitionId -and $_.Properties.policyDefinitionId -match '/policySetDefinitions/') {
            $policySetDefinition = $PolicySetDefinitions |? {$_.PolicyDefinitionId -eq $policyDefinitionId}
            $policySetDefinitionName = $policySetDefinition.Name
        }

        $policyParameter = ConvertTo-Json $_.Properties.parameters -Depth 99
        if ([string]::IsNullOrWhitespace($policyParameter)){
            $policyParameter = ConvertTo-Json @{}
        }

        if ($_.Properties.AssignIdentity -eq ''){
            $assignIdentity = $false
        } else {
            $assignIdentity = [System.Convert]::ToBoolean($_.Properties.AssignIdentity) 
        }

        $location = $_.Properties.Location
 
        @{'Name'=$name;'Scope'=$scope;'NotScope'=$notScope;'DisplayName'=$displayName;'Description'=$description;'Metadata'=$metadata;'PolicyDefinitionName'=$policyDefinitionName;'PolicySetDefinitionName'=$policySetDefinitionName;'PolicyParameter'=$policyParameter;'AssignIdentity'=$assignIdentity;'Location'=$location;}
    })

    $updatePolicySetAssignments = @($currentPolicySetAssignments | %{
        $name = $_.Name
        $scope = $_.Scope
        $policySetDefinitionName = $_.PolicySetDefinitionName 
        
        if ($PolicySetAssignments | ?{$_.Name -eq $name -and $_.Scope -eq $scope -and $_.PolicySetDefinitionName -eq $policySetDefinitionName}){
           $_ 
        }
    })

    $createPolicySetAssignments = @($PolicySetAssignments | %{
        $name = $_.Name
        $scope = $_.Scope
        $policySetDefinitionName = $_.PolicySetDefinitionName
        
        if (!($updatePolicySetAssignments | ?{$_.Name -eq $name -and $_.Scope -eq $scope -and $_.PolicySetDefinitionName -eq $policySetDefinitionName})){
            $_ 
         }
    })
    
    $desiredPolicySetAssignments = @()
    $desiredPolicySetAssignments += $createPolicySetAssignments
    $desiredPolicySetAssignments += $updatePolicySetAssignments

    $desiredPolicySetAssignmentResults = $desiredPolicySetAssignments | %{
        $name = $_.Name
        $scope = $_.Scope
        $notScope = $_.NotScope
        $displayName = $_.DisplayName
        $description = $_.Description
        $metadata = $_.Metadata
        #$policyDefinitionName = $_.PolicyDefinitionName
        $policySetDefinitionName = $_.PolicySetDefinitionName
        $policyParameter = $_.PolicyParameter
        $assignIdentity = $_.AssignIdentity
        $location = $_.Location
   
        if ($createPolicySetAssignments | ?{$_.Name -eq $name -and $_.Scope -eq $scope -and $_.PolicySetDefinitionName -eq $policySetDefinitionName}){
            #Get-AzPolicySetDefinition -Name 'xxx' seems faulty :<
            Write-Host @"
`$metadata=@'
$metadata
'@
`$policyParameter=@'
$policyParameter
'@
`$notScope=@'
$(ConvertTo-Json $notScope -Depth 99)
'@ 
`$notScope = ConvertFrom-Json `$notScope 

`$assignIdentity = [System.Convert]::ToBoolean('$assignIdentity')

`$policySetDefinition = Get-AzPolicySetDefinition |? {`$_.Name -eq '$policySetDefinitionName'}

if (!`$policySetDefinition) {
    throw "Policy set definition '$policySetDefinitionName' does not exist"
}

if (`$policySetDefinition) {
    New-AzPolicyAssignment -Name '$name' -Scope '$scope' -NotScope `$notScope -DisplayName '$displayName' -Description '$description' -Metadata `$metadata -PolicySetDefinition `$policySetDefinition -PolicyParameter `$policyParameter -AssignIdentity:`$assignIdentity -Location '$location' 
}
"@
            $policySetDefinition = $PolicySetDefinitions |? {$_.Name -eq $policySetDefinitionName}

            if (!$policySetDefinition) {
                throw "Policy definition '$policySetDefinitionName' does not exist"
            }

            if ($policySetDefinition) {
                $result = New-AzPolicyAssignment -Name $name -Scope $scope -NotScope $notScope -DisplayName $displayName -Description $description -Metadata $metadata -PolicySetDefinition $policySetDefinition -PolicyParameter $policyParameter -AssignIdentity:$assignIdentity -Location $location
                $_
            }
        } elseif ($updatePolicySetAssignments | ?{$_.Name -eq $name -and $_.Scope -eq $scope -and $_.PolicySetDefinitionName -eq $policySetDefinitionName}) {
            $desiredPolicySetAssignment = $PolicySetAssignments | ?{$_.Name -eq $name -and $_.Scope -eq $scope -and $_.PolicySetDefinitionName -eq $policySetDefinitionName}
            if ($desiredPolicySetAssignment)
            {
                $desiredName = $desiredPolicySetAssignment.Name
                $desiredScope = $desiredPolicySetAssignment.Scope
                $desiredNotScope = $desiredPolicySetAssignment.NotScope
                $desiredDisplayName = $desiredPolicySetAssignment.DisplayName
                $desiredDescription = $desiredPolicySetAssignment.Description
                $desiredMetadata = $desiredPolicySetAssignment.Metadata
                #$desiredPolicyDefinitionName = $desiredPolicySetAssignment.PolicyDefinitionName
                $desiredPolicySetDefinitionName = $desiredPolicySetAssignment.PolicySetDefinitionName
                $desiredPolicyParameter = $desiredPolicySetAssignment.PolicyParameter
                $desiredAssignIdentity = $desiredPolicySetAssignment.AssignIdentity
                $desiredLocation = $desiredPolicySetAssignment.Location

                if ($desiredName -ne $name){
                    Write-Host @"
                    Desired Name:
                    $desiredName

                    Actual Name:
                    $name
"@
                }                    

                if ($desiredScope -ne $scope){
                    Write-Host @"
                    Desired Scope:
                    $desiredScope

                    Actual Scope:
                    $scope
"@
                }

                if ($desiredNotScope -ne $notScope){
                    Write-Host @"
                    Desired Not Scope:
                    $(ConvertTo-Json $desiredNotScope -Depth 99)

                    Actual Not Scope:
                    $(ConvertTo-Json $notScope -Depth 99)
"@
                }

                if ($desiredDisplayName -ne $displayName){
                    Write-Host @"
                    Desired Display Name:
                    $desiredDisplayName

                    Actual Display Name:
                    $displayName
"@
                }

                if ($desiredDescription -ne $description){
                    Write-Host @"
                    Desired Description:
                    $desiredDescription

                    Current Description:
                    $description
"@
                }

                if ($desiredMetadata -ne $metadata){
                    Write-Host @"
                    Desired Metadata:
                    $desiredMetadata

                    Actual Metadata:
                    $metadata
"@
                }     

                if ($desiredPolicySetDefinitionName -ne $policySetDefinitionName){
                    Write-Host @"
                    Desired Policy Set Definition Name:
                    $desiredPolicySetDefinitionName

                    Actual Policy Set Definition Name:
                    $policySetDefinitionName
"@
                }     

                if ($desiredPolicyParameter -ne $policyParameter){
                    Write-Host @"
                    Desired Policy Parameter:
                    $desiredPolicyParameter

                    Actual Policy Parameter:
                    $policyParameter
"@
                }     

                if ($desiredAssignIdentity -ne $assignIdentity){
                    Write-Host @"
                    Desired Assign Identity:
                    $desiredAssignIdentity

                    Actual Assign Identity:
                    $assignIdentity
"@
                }     

                if ($desiredLocation -ne $location){
                    Write-Host @"
                    Desired Location:
                    $desiredLocation

                    Actual Location:
                    $location
"@
                }

                if ($desiredName -ne $name -or $desiredScope -ne $scope -or $desiredNotScope -ne $notScope -or $desiredDisplayName -ne $displayName -or $desiredDescription -ne $description -or $desiredMetadata -ne $metadata -or $desiredPolicySetDefinitionName -ne $policySetDefinitionName -or $desiredPolicyParameter -ne $policyParameter -or $desiredAssignIdentity -ne $assignIdentity -or $desiredLocation -ne $location ) {
                    #Get-AzPolicySetDefinition -Name 'xxx' seems faulty :<
                    Write-Host @"
`$metadata=@'
$metadata
'@
`$desiredMetadata=@'
$desiredMetadata
'@
`$policyParameter=@'
$policyParameter
'@
`$desiredPolicyParameter=@'
$desiredPolicyParameter
'@
`$notScope=@'
$(ConvertTo-Json $notScope -Depth 99)
'@ 
`$notScope = ConvertFrom-Json `$notScope 

`$desiredNotScope=@'
$(ConvertTo-Json $desiredNotScope -Depth 99)
'@ 
`$desiredNotScope = ConvertFrom-Json `$desiredNotScope

`$assignIdentity = [System.Convert]::ToBoolean('$assignIdentity')
`$desiredAssignIdentity = [System.Convert]::ToBoolean('$desiredAssignIdentity')

`$policySetDefinition = Get-AzPolicySetDefinition |? {`$_.Name -eq '$policySetDefinitionName'}
if ('$policySetDefinitionName' -eq '$desiredPolicySetDefinitionName'){
    `$desiredPolicySetDefinition = `$policySetDefinition
} else {
    `$desiredPolicySetDefinition = Get-AzPolicySetDefinition |? {`$_.Name -eq '$desiredPolicySetDefinitionName'}
}

if (!`$policySetDefinition) {
    throw "Policy set definition '$policySetDefinitionName' does not exist"
}

if (!`$desiredPolicySetDefinition) {
    throw "Desired policy set definition '$desiredPolicySetDefinitionName' does not exist"
}

if (`$policySetDefinition -and `$desiredPolicySetDefinition) {
    if ('$desiredName' -ne '$name' -or '$desiredScope' -ne '$scope' -or '$desiredPolicySetDefinitionName' -ne '$policySetDefinitionName' -or `$desiredPolicySetDefinition -ne `$policySetDefinition -or `$desiredPolicyParameter -ne `$policyParameter){
        Get-AzPolicyAssignment -Name '$name' -Scope '$scope' -PolicyDefinitionId `$policySetDefinition.PolicyDefinitionId | ?{`$_.Name -eq '$name' -and `$_.Scope -eq '$scope' -and `$_.PolicyDefinitionId -eq `$policySetDefinition.PolicyDefinitionId} | Remove-AzRoleAssignment
        New-AzPolicyAssignment -Name '$desiredName' -Scope '$desiredScope' -NotScope `$desiredNotScope -DisplayName '$desiredDisplayName' -Description '$desiredDescription' -Metadata `$desiredMetadata -PolicyDefinition `$desiredPolicySetDefinition -PolicyParameter `$desiredPolicyParameter -AssignIdentity:`$desiredAssignIdentity -Location '$desiredLocation' 
    } elseif (`$desiredNotScope -ne `$notScope -or '$desiredDisplayName' -ne '$displayName' -or '$desiredDescription' -ne '$description' -or `$desiredMetadata -ne `$metadata -or `$desiredAssignIdentity -ne `$assignIdentity -or '$desiredLocation' -ne '$location') {
        Set-AzPolicyAssignment -Name '$desiredName' -Scope '$desiredScope' -NotScope `$desiredNotScope -DisplayName '$desiredDisplayName' -Description '$desiredDescription' -Metadata `$desiredMetadata -AssignIdentity:`$desiredAssignIdentity -Location '$desiredLocation' 
    }
}
"@
                    #Get-AzPolicySetDefinition -Name 'xxx' seems faulty :<
                    $policySetDefinition = $PolicySetDefinitions |? {$_.Name -eq $policySetDefinitionName}
                    if ($policySetDefinitionName -eq $desiredPolicySetDefinitionName){
                        $desiredPolicySetDefinition = $policySetDefinition
                    } else {
                        $desiredPolicySetDefinition = $PolicySetDefinitions |? {$_.Name -eq $desiredPolicySetDefinitionName}
                    }

                    if (!$policySetDefinition) {
                        throw "Policy set definition '$policySetDefinitionName' does not exist"
                    }

                    if (!$desiredPolicySetDefinition) {
                        throw "Desired policy set definition '$desiredPolicySetDefinitionName' does not exist"
                    }

                    if ($policySetDefinition -and $desiredPolicySetDefinition) {
                        if ($desiredName -ne $name -or $desiredScope -ne $scope -or $desiredPolicySetDefinitionName -ne $policySetDefinitionName -or $desiredPolicySetDefinition -ne $policySetDefinition -or $desiredPolicyParameter -ne $policyParameter){
                            $result = Get-AzPolicyAssignment -Name $name -Scope $scope -PolicyDefinitionId $policyDefinition.PolicyDefinitionId | ?{$_.Name -eq $name -and $_.Scope -eq $scope -and $_.PolicyDefinitionId -eq $policySetDefinition.PolicyDefinitionId} | Remove-AzRoleAssignment
                            $result = New-AzPolicyAssignment -Name $desiredName -Scope $desiredScope -NotScope $desiredNotScope -DisplayName $desiredDisplayName -Description $desiredDescription -Metadata $desiredMetadata -PolicyDefinition $desiredPolicySetDefinition -PolicyParameter $desiredPolicyParameter -AssignIdentity:$desiredAssignIdentity -Location $desiredLocation
                            $_
                        } elseif ($desiredNotScope -ne $notScope -or $desiredDisplayName -ne $displayName -or $desiredDescription -ne $description -or $desiredMetadata -ne $metadata -or $desiredAssignIdentity -ne $assignIdentity -or $desiredLocation -ne $location) {
                            $result = Set-AzPolicyAssignment -Name $desiredName -Scope $desiredScope -NotScope $desiredNotScope -DisplayName $desiredDisplayName -Description $desiredDescription -Metadata $desiredMetadata -AssignIdentity:$desiredAssignIdentity -Location $desiredLocation 
                            $_
                        }
                    } 
                } else {
                    $_
                }
            }
        }
    }
   
    if ($DeleteUnknownPolicySetAssignment) {
        @($currentPolicySetAssignments | %{
            $name = $_.Name
            $scope = $_.Scope
            $policySetDefinitionName = $_.PolicySetDefinitionName
    
            if (!($PolicySetAssignments | ?{$_.Name -eq $name -and $_.Scope -eq $scope -and $_.PolicySetDefinitionName -eq $policySetDefinitionName})){
                #Get-AzPolicySetDefinition -Name 'xxx' seems faulty :<
                Write-Host @"
`$policySetDefinition = Get-AzPolicySetDefinition |? {`$_.Name -eq '$policySetDefinitionName'}
if (!`$policySetDefinition) {
    throw "Policy set definition '$policySetDefinitionName' does not exist"
}

`$policyAssignmentId = Get-AzPolicyAssignment -Name '$name' -Scope '$scope' -PolicyDefinitionId `$policySetDefinition.PolicyDefinitionId | ?{`$_.Name -eq '$name' -and `$_.Properties.scope -eq '$scope' -and `$_.Properties.policyDefinitionId -eq `$policySetDefinition.PolicyDefinitionId} | %{`$_.PolicyAssignmentId}
Remove-AzPolicyAssignment -Id `$policyAssignmentId
"@

                #Get-AzPolicySetDefinition -Name 'xxx' seems faulty :<
                $policySetDefinition = Get-AzPolicySetDefinition |? {$_.Name -eq $policySetDefinitionName}
                if (!$policySetDefinition) {
                    throw "Policy set definition '$policySetDefinitionName' does not exist"
                }

                $policyAssignmentId = Get-AzPolicyAssignment -Name $name -Scope $scope -PolicyDefinitionId $policySetDefinition.PolicyDefinitionId | ?{$_.Name -eq $name -and $_.Properties.scope -eq $scope -and $_.Properties.policyDefinitionId -eq $policySetDefinition.PolicyDefinitionId} | %{$_.PolicyAssignmentId}
                $result = Remove-AzPolicyAssignment -Id $policyAssignmentId
            }
        })
    }

    $desiredPolicySetAssignmentResults
}

#ensure there is an AD Tenant
#https://portal.azure.com/#create/Microsoft.AzureActiveDirectory

#ensure you are logged in with user that has rights to manage subscriptions and management groups
#https://portal.azure.com/#blade/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/Properties
#Under Access management for Azure resources
#select  "yes" for can manage access to all azure subscriptions and management groups in this directory

#ensure you are logged in with a user that has rights to create subscriptions:
#https://docs.microsoft.com/bs-latn-ba/azure/azure-resource-manager/grant-access-to-create-subscription?tabs=azure-powershell
# $EnrollmentAccountId = Get-AzEnrollmentAccount | %{$_.ObjectId}
# $UserObjectId =  Get-AzADUser -UserPrincipalName "taliesins@TaliTest01.onmicrosoft.com" | %{$_.Id}
# New-AzureRmRoleAssignment -RoleDefinitionName Owner -ObjectId $UserObjectId -Scope "/providers/Microsoft.Billing/enrollmentAccounts/$EnrollmentAccountId"

#ensure the Az Context has been set for the tenant
$TenantId = "1931b7d3-bd07-4b36-9814-adf4ad406860"

#ensure that you are logged in
#Connect-AzAccount -TenantId $TenantId

$FullyManage = $true

$tenantContext = Connect-Context -TenantId $TenantId

if (!$tenantContext.ManagementGroupName) {
    throw "The tenant $TenantId does not exist or is not accessible to this user"
}

if (!$tenantContext.EnrollmentAccountId) {
    Write-Host "No enrollment account, will not be able to create subscriptions"
}

$DesiredState = [System.IO.File]::ReadAllLines((Resolve-Path 'DesiredState.json')) | ConvertFrom-Json


#Create definitions at root, then all management groups can apply them at any level
$ManagementGroups = Set-DscManagementGroup -DesiredState $DesiredState -DeleteUnknownManagementGroups $FullyManage
$Subscriptions = Set-DscSubscription -DesiredState $DesiredState -CancelUnknownSubscriptions $FullyManage
$AdGroups = Set-DscAdGroup -DesiredState $DesiredState -DeleteUnknownAdGroups $FullyManage -DeleteUnknownAdGroupMembers $FullyManage

$RoleDefinitions = Set-DscRoleDefinition -RoleDefinitionPath (Resolve-Path 'RoleDefinitions')
$PolicyDefinitions = Set-DscPolicyDefinition -ManagementGroupName $tenantContext.ManagementGroupName -PolicyDefinitionPath (Resolve-Path 'PolicyDefinitions')
$PolicySetDefinitions = Set-DscPolicySetDefinition -ManagementGroupName $tenantContext.ManagementGroupName -PolicySetDefinitionPath (Resolve-Path 'PolicySetDefinitions')
$BlueprintDefinitions = Set-DscBlueprintDefinition -ManagementGroupName $tenantContext.ManagementGroupName

#Add role to management group or subscription
$RoleAssignments = Set-DscRoleAssignment -DesiredState $DesiredState

#Add policy to management group or subscription
$PolicyAssignments = Set-DscPolicyAssignment -DesiredState $DesiredState

#Add policy set to management group or subscription
$PolicySetAssignments = Set-DscPolicySetAssignment -DesiredState $DesiredState

#BluePrintAssignments

#https://docs.microsoft.com/en-us/rest/api/policy-insights/
#Do this to show the number of non complaint resources
#https://docs.microsoft.com/en-us/azure/governance/policy/assign-policy-powershell

#Add role to management group
#$EnvironmentProvisioningManagementGroupADGroup = Get-AzADGroup -SearchString "Environment Provisioning"

#$ProductionManagementGroupName = "Production"
#$ProductionManagementGroupId = $parentIdPrefix + $ProductionManagementGroupName
#New-AzRoleAssignment -ObjectId $EnvironmentProvisioningManagementGroupADGroup.ObjectId -RoleDefinitionName "Reader" -Scope $ProductionManagementGroupId

#$DevTestManagementGroupName = "DevTest"
#$DevTestManagementGroupId = $parentIdPrefix + $DevTestManagementGroupName
#New-AzRoleAssignment -ObjectId $EnvironmentProvisioningManagementGroupADGroup.ObjectId -RoleDefinitionName "Reader" -Scope $ProductionManagementGroupId

#$ManagementGroupName = "ProductionHub1LOB2CICD"
#$ManagementGroupId = $parentIdPrefix + $ManagementGroupName
#New-AzRoleAssignment -ObjectId $EnvironmentProvisioningManagementGroupADGroup.ObjectId -RoleDefinitionName "Owner" -Scope $ManagementGroupId

#$BYOPManagementGroupName = $ManagementGroupName + "BYOP"
#$BYOPManagementGroupId = $parentIdPrefix + $BYOPManagementGroupName
#$SubscriptionId = "87c5bf6c-dcba-43d2-bf32-6f16f072b472"
#$EnvironmentAdminsManagementGroupADGroup = Get-AzADGroup -SearchString "$BYOPManagementGroupName - Admins"
#$EnvironmentDevelopersManagementGroupADGroup = Get-AzADGroup -SearchString "$BYOPManagementGroupName - Developers"
#New-AzRoleAssignment -ObjectId $EnvironmentAdminsManagementGroupADGroup.ObjectId -RoleDefinitionName "Resource Policy Contributor" -Scope $BYOPManagementGroupId
#New-AzRoleAssignment -ObjectId $EnvironmentAdminsManagementGroupADGroup.ObjectId -RoleDefinitionName "Management Group Reader" -Scope $BYOPManagementGroupId
#New-AzRoleAssignment -ObjectId $EnvironmentAdminsManagementGroupADGroup.ObjectId -RoleDefinitionName "Owner" -Scope $SubscriptionGroupId
#New-AzRoleAssignment -ObjectId $EnvironmentDevelopersManagementGroupADGroup.ObjectId -RoleDefinitionName "Management Group Reader" -Scope $BYOPManagementGroupId
#New-AzRoleAssignment -ObjectId $EnvironmentDevelopersManagementGroupADGroup.ObjectId -RoleDefinitionName "Reader" -Scope $SubscriptionGroupId

