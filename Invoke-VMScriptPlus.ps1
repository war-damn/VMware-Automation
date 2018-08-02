#Source: 	Luc Dekens
#			http://www.lucd.info/2017/09/14/invoke-vmscriptplus/
#
#requires -Version 5.0
#requires -Modules VMware.VimAutomation.Core
 
class MyOBN:System.Management.Automation.ArgumentTransformationAttribute
{
    [ValidateSet(
        'Cluster','Datacenter','Datastore','DatastoreCluster','Folder',
        'VirtualMachine','VirtualSwitch','VMHost','VIServer'
    )]
    [String]$Type
 
    MyOBN([string]$Type)
    {
        $this.Type = $Type
    }
    [object] Transform([System.Management.Automation.EngineIntrinsics]$engineIntrinsics,[object]$inputData)
    {
        if ($inputData -is [string])
        {
            if (-NOT [string]::IsNullOrWhiteSpace( $inputData ))
            {
                $cmdParam = "-$(if($this.Type -eq 'VIServer'){'Server'}else{'Name'}) $($inputData)"
                $sCmd = @{
                    Command = "Get-$($this.Type.Replace('VirtualMachine','VM')) $($cmdParam)"
                }
                return (Invoke-Expression @sCmd)
            }
        }
        elseif($inputData.GetType().Name -match "$($this.Type)Impl")
        {
            return $inputData
        }
        elseif($inputData.GetType().Name -eq 'Object[]')
        {
            return ($inputData | %{
                if($_ -is [String])
                {
                    return (Invoke-Expression -Command "Get-$($this.Type.Replace('VirtualMachine','VM')) -Name `$_")
                }
                elseif($_.GetType().Name -match "$($this.Type)Impl")
                {
                    $_
                }
            })
        }
        throw [System.IO.FileNotFoundException]::New()
    }
}
 
function Invoke-VMScriptPlus
{
<#
.SYNOPSIS
  Runs a script in a Linux guest OS.
  The script can use the SheBang to indicate which interpreter to use.
.DESCRIPTION
  This function will launch a script in a Linux guest OS.
  The script supports the SheBang line for a limited set of interpreters.
.NOTES
  Author:  Luc Dekens
.PARAMETER VM
  Specifies the virtual machines on whose guest operating systems
  you want to run the script.
.PARAMETER GuestUser
  Specifies the user name you want to use for authenticating with the
  virtual machine guest OS.
.PARAMETER GuestPassword
  Specifies the password you want to use for authenticating with the
  virtual machine guest OS.
.PARAMETER GuestCredential
  Specifies a PSCredential object containing the credentials you want
  to use for authenticating with the virtual machine guest OS.
.PARAMETER ScriptText
  Provides the text of the script you want to run. You can also pass
  to this parameter a string variable containing the path to the script.
  Note that the function will add a SheBang line, based on the ScriptType,
  if none is provided in the script text.
.PARAMETER ScriptType
  The supported Linux interpreters.
  Currently these are bash,perl,python3,nodejs,php,lua
.PARAMETER CRLF
  Switch to indicate of the NL that is returned by Linux, shall be
  converted to a CRLF
.PARAMETER Server
  Specifies the vCenter Server systems on which you want to run the
  cmdlet. If no value is passed to this parameter, the command runs
  on the default servers. For more information about default servers,
  see the description of Connect-VIServer.  
.EXAMPLE
  $pScript = @'
  #!/usr/bin/env perl
  use strict;
  use warnings;
 
  print "Hello world\n";
  '@
    $sCode = @{
      VM = $VM
      GuestCredential = $cred
      ScriptType = 'perl'
      ScriptText = $pScript
  }
  Invoke-VMScriptPlus @sCode
.EXAMPLE
  $pScript = @'
  print("Happy 10th Birthday PowerCLI!") 
  '@
    $sCode = @{
      VM = $VM
      GuestCredential = $cred
      ScriptType = 'python3'
      ScriptText = $pScript
  }
  Invoke-VMScriptPlus @sCode
#>    
    [cmdletbinding()]    
    param(
        [parameter(Mandatory=$true,ValueFromPipeline=$true)]
        [MyOBN('VirtualMachine')]
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.VirtualMachine[]]$VM,
        [Parameter(Mandatory=$true,ParameterSetName='PlainText')]
        [String]$GuestUser,
        [Parameter(Mandatory=$true,ParameterSetName='PlainText')]
        [String]$GuestPassword,
        [Parameter(Mandatory=$true,ParameterSetName='PSCredential')]
        [PSCredential[]]$GuestCredential,
        [Parameter(Mandatory=$true)]
        [String]$ScriptText,
        [Parameter(Mandatory=$true)]
        [ValidateSet('bash','perl','python3','nodejs','php','lua')]
        [String]$ScriptType,
        [Switch]$CRLF,
        [MyOBN('VIServer')]
        [VMware.VimAutomation.ViCore.Types.V1.VIServer]$Server = $global:DefaultVIServer
 
    )
 
    Begin
    {
        $si = Get-View ServiceInstance
        $guestMgr = Get-View -Id $si.Content.GuestOperationsManager
        $gFileMgr = Get-View -Id $guestMgr.FileManager
        $gProcMgr = Get-View -Id $guestMgr.ProcessManager
 
        $shebangTab = @{
            'bash' = '#!/usr/bin/env bash'
            'perl' = '#!/usr/bin/env perl'
            'python3' = '#!/usr/bin/env python3'
            'nodejs' = '#!/usr/bin/env nodejs'
            'php' = '#!/usr/bin/env php'
            'lua' = '#!/usr/bin/env lua'
        }
    }
 
    Process
    {
        foreach($vmInstance in $VM){
            # Preamble
            if($vmInstance.PowerState -ne 'PoweredOn')
            {
                Write-Error "VM $($vmInstance.Name) is not powered on"
                continue
            }
            if($vmInstance.ExtensionData.Guest.ToolsRunningStatus -ne 'guestToolsRunning')
            {
                Write-Error "VMware Tools are not running on VM $($vmInstance.Name)"
                continue
            }
 
            $moref = $vmInstance.ExtensionData.MoRef
 
            # Test if code contains a SheBang, otherwise add it
            $targetCode = $shebangTab[$ScriptType]
            if($ScriptText -notmatch "^$($targetCode)"){
                $ScriptText = "$($targetCode)`n`r$($ScriptText)"
            }
    
            # Create Authentication Object (User + Password)
            
            if($PSCmdlet.ParameterSetName -eq 'PSCredential')
            {
                $GuestUser = $GuestCredential.GetNetworkCredential().username
                $GuestPassword = $GuestCredential.GetNetworkCredential().password
            }
    
            $auth = New-Object VMware.Vim.NamePasswordAuthentication
            $auth.InteractiveSession = $false
            $auth.Username = $GuestUser
            $auth.Password = $GuestPassword
            
            # Copy script to temp file in guest
            
            # Create temp file for script
            Try{
                $tempFile = $gFileMgr.CreateTemporaryFileInGuest($moref,$auth,"$($env:USERNAME)_","_$($PID)",'/tmp')
            }
            Catch{
                Throw "$error[0].Exception.Message"
            }
            
            # Create temp file for output
            Try{
                $tempOutput = $gFileMgr.CreateTemporaryFileInGuest($moref,$auth,"$($env:USERNAME)_","_$($PID)_output",'/tmp')
            }
            Catch{
                Throw "$error[0].Exception.Message"
            }
           
            # Copy script to temp file
            $lCode = $ScriptText.Split("`r") -join ''
            $attr = New-Object VMware.Vim.GuestFileAttributes
            $clobber = $true
            $filePath = $gFileMgr.InitiateFileTransferToGuest($moref,$auth,$tempFile,$attr,$lCode.Length,$clobber)
            $copyResult = Invoke-WebRequest -Uri $filePath -Method Put -Body $lCode
            
            if($copyResult.StatusCode -ne 200)
            {
                Throw "ScripText copy failed!`rStatus $($copyResult.StatusCode)`r$(($copyResult.Content | %{[char]$_}) -join '')"
            }
                
            # Make temp file executable
            $spec = New-Object VMware.Vim.GuestProgramSpec
            $spec.Arguments = "751 $($tempFile.Split('/')[-1])"
            $spec.ProgramPath = '/bin/chmod'
            $spec.WorkingDirectory = '/tmp'
            Try{
                $procId = $gProcMgr.StartProgramInGuest($moref,$auth,$spec)
            }
            Catch{
                Throw "$error[0].Exception.Message"
            }
            
            # Run temp file
            
            $spec = New-Object VMware.Vim.GuestProgramSpec
            $spec.Arguments = " > $($tempOutput)"
            $spec.ProgramPath = "$($tempFile)"
            $spec.WorkingDirectory = '/tmp'
            Try{
                $procId = $gProcMgr.StartProgramInGuest($moref,$auth,$spec)
            }
            Catch{
                Throw "$error[0].Exception.Message"
            }
            
            # Wait for script to finish
            Try{
                $pInfo = $gProcMgr.ListProcessesInGuest($moref,$auth,@($procId))
                while($pInfo.EndTime -eq $null){
                    sleep 1
                    $pInfo = $gProcMgr.ListProcessesInGuest($moref,$auth,@($procId))
                }
            }
            Catch{
                Throw "$error[0].Exception.Message"
            }
 
            # Retrieve output from script
            
            $fileInfo = $gFileMgr.InitiateFileTransferFromGuest($moref,$auth,$tempOutput)
            $fileContent = Invoke-WebRequest -Uri $fileInfo.Url -Method Get
            if($fileContent.StatusCode -ne 200)
            {
                Throw "Retrieve of script output failed!`rStatus $($fileContent.Status)`r$(($fileContent.Content | %{[char]$_}) -join '')"
            }
            
            # Clean up
 
            # Remove output file
            $gFileMgr.DeleteFileInGuest($moref,$auth,$tempOutput)
            
            # Remove temp script file
            $gFileMgr.DeleteFileInGuest($moref,$auth,$tempFile)
    
            New-Object PSObject -Property @{
                VM = $vmInstance
                ScriptOutput = &{
                    $out = ($fileContent.Content | %{[char]$_}) -join ''
                    if($CRLF)
                    {
                        $out.Replace("`n","`n`r")
                    }
                    else
                    {
                        $out
                    }
                }
                Pid = $procId
                PidOwner = $pInfo.Owner
                Start = $pInfo.StartTime
                Finish = $pInfo.EndTime
                ExitCode = $pInfo.ExitCode
                ScriptType = $ScriptType
                ScriptText = $ScriptText
            }
        }
    }
}