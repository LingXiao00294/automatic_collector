param(
    [string]$GameRoot = "D:/Programs/Steam/steamapps/common/Don't Starve Together"
)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimeRoot = Join-Path $projectRoot '.runtime/engine_smoke'
$gameDirectory = Join-Path $runtimeRoot 'game'
$binDirectory = Join-Path $gameDirectory 'bin64'
$modDirectory = Join-Path $gameDirectory 'mods/automatic_collector'
$storageDirectory = Join-Path $runtimeRoot 'storage'
$clusterDirectory = Join-Path $storageDirectory 'collector_test/Cluster_smoke'
$masterDirectory = Join-Path $clusterDirectory 'Master'
New-Item -ItemType Directory -Force -Path $binDirectory,$modDirectory,$masterDirectory | Out-Null

# Only a new isolated test directory is written. Installed game/mod/save files are read.
$gameData = [IO.Path]::GetFullPath((Join-Path $GameRoot 'data'))
$dataDirectory = Join-Path $gameDirectory 'data'
if (Test-Path -LiteralPath $dataDirectory) {
    $existing = Get-Item -LiteralPath $dataDirectory
    if ($existing.LinkType -ne 'Junction' -or [IO.Path]::GetFullPath($existing.Target[0]) -ne $gameData) {
        throw "Unexpected test data directory: $dataDirectory"
    }
} else {
    New-Item -ItemType Junction -Path $dataDirectory -Target $gameData | Out-Null
}
$exeName = 'dontstarve_dedicated_server_nullrenderer_x64.exe'
Copy-Item -LiteralPath (Join-Path $GameRoot "bin64/$exeName") -Destination $binDirectory
Get-ChildItem -LiteralPath (Join-Path $GameRoot 'bin64') -Filter '*.dll' | Copy-Item -Destination $binDirectory
foreach ($name in @('modinfo.lua','modmain.lua','modicon.xml','modicon.tex','scripts','anim','images','sound')) {
    Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination $modDirectory -Recurse -Force
}
New-Item -ItemType Directory -Force -Path (Join-Path $modDirectory 'tests') | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'tests/engine_smoke.lua') -Destination (Join-Path $modDirectory 'tests')
Add-Content -LiteralPath (Join-Path $modDirectory 'modmain.lua') -Value 'modimport("tests/engine_smoke.lua")' -Encoding utf8
Set-Content -LiteralPath (Join-Path $binDirectory 'steam_appid.txt') -Value '322330' -Encoding ascii
Set-Content -LiteralPath (Join-Path $clusterDirectory 'cluster.ini') -Encoding ascii -Value @'
[GAMEPLAY]
game_mode = endless
max_players = 1
pvp = false
pause_when_empty = false
[NETWORK]
cluster_name = Automatic Collector isolated smoke test
lan_only_cluster = true
offline_cluster = true
[MISC]
console_enabled = true
[SHARD]
shard_enabled = false
'@
Set-Content -LiteralPath (Join-Path $masterDirectory 'server.ini') -Encoding ascii -Value @'
[NETWORK]
server_port = 10999
[STEAM]
authentication_port = 11998
master_server_port = 11997
'@
Set-Content -LiteralPath (Join-Path $masterDirectory 'modoverrides.lua') -Value 'return { automatic_collector = { enabled = true, configuration_options = { matching_only = false } } }' -Encoding ascii
Set-Content -LiteralPath (Join-Path $masterDirectory 'worldgenoverride.lua') -Value 'return { override_enabled = true, preset = "SURVIVAL_TOGETHER", overrides = { world_size = "small", season_start = "spring" } }' -Encoding ascii
Push-Location $binDirectory
try {
    & (Join-Path $binDirectory $exeName) -persistent_storage_root $storageDirectory -conf_dir collector_test -cluster Cluster_smoke -shard Master -offline -skip_update_server_mods -disabledatacollection -bind_ip 127.0.0.1 | Out-Null
} finally {
    Pop-Location
}
$log = Join-Path $masterDirectory 'server_log.txt'
Select-String -LiteralPath $log -Pattern 'AC_SMOKE' | ForEach-Object { $_.Line }
if (-not (Select-String -LiteralPath $log -Pattern 'AC_SMOKE SUCCESS' -Quiet)) {
    throw "Engine smoke test failed; inspect $log"
}
