# Security descriptor policy tests; native task/file enforcement is a separate test.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../scripts/Vhdx-Protection.ps1"
$sid='S-1-5-21-111-222-333-1001'
$good="O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;$sid)"
Assert-ArchVhdxAcl -Sddl $good -OwnerSid $sid -Kind File
Assert-ArchVhdxAcl -Sddl "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;$sid)" -OwnerSid $sid -Kind Directory
Assert-ArchVhdxAcl -Sddl "O:BAG:BAD:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGX;;;$sid)" -OwnerSid $sid -Kind Task
Write-Host 'PASS explicit protected file/directory/task ACL policy'
$cases=@(
    $good.Replace('O:BA',"O:$sid"),
    $good.Replace('D:P','D:'),
    $good.Replace(';;FR;', ';;FWFR;'),
    ($good+'(A;;FA;;;BU)'),
    $good.Replace(";;;$sid)",';;;BU)'),
    $good.Replace('(A;;FR;', '(A;ID;FR;'),
    $good.Replace('(A;;FA;;;SY)',''),
    $good.Replace('(A;;FR;', '(D;;FR;')
)
foreach($bad in $cases){
    $failed=$false
    try { Assert-ArchVhdxAcl -Sddl $bad -OwnerSid $sid -Kind File } catch {$failed=$true}
    if(!$failed){throw 'Unsafe ACL accepted'}
}
Write-Host "PASS $($cases.Count) unsafe owner/inheritance/write/extra-principal/missing-principal ACLs rejected"
