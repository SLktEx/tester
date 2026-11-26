function Assert-ArchVhdxAcl {
    param([Parameter(Mandatory)][string]$Sddl,
          [Parameter(Mandatory)][string]$OwnerSid,
          [Parameter(Mandatory)][ValidateSet('File','Directory','Task')][string]$Kind)
    $descriptor=[Security.AccessControl.RawSecurityDescriptor]::new($Sddl)
    if($descriptor.Owner.Value -ne 'S-1-5-32-544' -or
       !($descriptor.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected)){
        throw 'Protected object must be owned by Administrators with inheritance disabled'
    }
    $acl=$descriptor.DiscretionaryAcl
    if(!$acl -or $acl.Count -ne 3){throw 'Protected DACL must contain exactly three explicit allow entries'}
    $seen=@{}
    foreach($ace in $acl){
        if($ace -isnot [Security.AccessControl.CommonAce] -or
           $ace.AceType -ne [Security.AccessControl.AceType]::AccessAllowed){throw 'Unexpected ACL entry type'}
        $expectedFlags=if($Kind -eq 'Directory'){3}else{0}
        if([int]$ace.AceFlags -ne $expectedFlags){throw 'Unexpected inherited/propagation ACL flags'}
        $principal=$ace.SecurityIdentifier.Value
        if($seen.ContainsKey($principal)){throw 'Duplicate ACL principal'}
        $seen[$principal]=$true
        $mask=[BitConverter]::ToUInt32([BitConverter]::GetBytes($ace.AccessMask),0)
        if($principal -in 'S-1-5-18','S-1-5-32-544'){
            $allowed=if($Kind -eq 'Task'){@(0x1f01ff,268435456)}else{@(0x1f01ff)}
        }elseif($principal -ceq $OwnerSid){
            $allowed=switch($Kind){File {@(0x120089)} Directory {@(0x1200a9)} Task {@(0x1200a9,2684354560L)}}
        }else{throw 'Unexpected principal on protected object'}
        if($mask -notin $allowed){throw 'Unexpected write/control rights on protected object'}
    }
    foreach($principal in 'S-1-5-18','S-1-5-32-544',$OwnerSid){if(!$seen.ContainsKey($principal)){throw 'Required ACL principal missing'}}
}
