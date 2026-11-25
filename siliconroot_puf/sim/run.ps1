# -------------------------------
# Author      : najamdesktop\najam
# Description : Windows port of run.sh - same interface, same modes.
#               The compile line puts every option BEFORE the source
#               files because the Windows build of Icarus Verilog stops
#               option parsing at the first source file: the bash form
#               `... -o my_sim_exe $1.sv -f f_list.f` fails on this host
#               with `-f: No such file or directory`. The canonical
#               run.sh needs a Linux iverilog (WSL) to run as written.
# -------------------------------
# Guide
# -------------------------------
#   help          | .\run.ps1 -h
#   clean         | .\run.ps1 -clean
#   compile only  | .\run.ps1 tb_siliconroot_puf -compile
#   run + wave    | .\run.ps1 tb_siliconroot_puf -dump     (writes simulation.vcd)
#   run + gtkwave | .\run.ps1 tb_siliconroot_puf -gui      (gtkwave not on this host: writes the wave only)
#   modelsim      | not installed on this host - use -dump
# -------------------------------

function Show-Help {
  Write-Host "-------------------------------"
  Write-Host "- HELP"
  Write-Host "-------------------------------"
  Write-Host "  run command     | .\run.ps1 -h or .\run.ps1 --help"
  Write-Host "  run command     | .\run.ps1 -clean"
  Write-Host "  run command     | .\run.ps1 tb_testbench_name -gui"
  Write-Host "  dump command    | .\run.ps1 tb_testbench_name -dump"
  Write-Host "  compile only    | .\run.ps1 tb_testbench_name -compile"
  Write-Host "The bash form of this block: run it under WSL, see run.sh."
}

function Show-Error {
  Write-Host "-------------------------------"
  Write-Host "Use .\run.ps1 -h or .\run.ps1 --help"
  Write-Host "-------------------------------"
}

function Invoke-Clean {
  Remove-Item -Path my_sim*, *.vcd, work, transcript, vsim.wlf -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "!! Files and directories created during compilation and runtime cleaned !! "
}

# Fall back to the local Icarus install when it is not on PATH.
if (-not (Get-Command iverilog -ErrorAction SilentlyContinue)) {
  if (Test-Path 'C:\iverilog\bin\iverilog.exe') {
    $env:Path = 'C:\iverilog\bin;' + $env:Path
  } else {
    Write-Host "iverilog not found on PATH - install Icarus Verilog first."
    exit 1
  }
}

if ($args.Count -lt 1) { Show-Error; exit 1 }
$top = $args[0]
$mode = if ($args.Count -ge 2) { $args[1] } else { '' }

if ($top -eq '-clean') { Invoke-Clean; exit 0 }
if ($top -in '-h', '--help', '/?') { Show-Help; exit 0 }

function Invoke-Compile {
  Write-Host "-------------------------------"
  Write-Host "- Compiling RTL"
  Write-Host "-------------------------------"
  # Options first, sources last - the working order on this Windows host.
  # f_list.f holds the RTL only, the bench itself comes in as the last source.
  & iverilog -s $top -g2012 -f f_list.f -o my_sim_exe "$top.sv"
  return $LASTEXITCODE
}

switch ($mode) {
  '-compile' {
    Invoke-Clean
    exit (Invoke-Compile)
  }
  '-dump' {
    Invoke-Clean
    $rc = Invoke-Compile
    if ($rc -ne 0) { exit $rc }
    Write-Host "-------------------------------"
    Write-Host "- Running in dumping mode (simulation.vcd)"
    Write-Host "-------------------------------"
    # +dump is this bench's plusarg for $dumpfile (run.sh's -dump mode omits it).
    & vvp my_sim_exe +kat=kat_vectors.txt +dump
    exit $LASTEXITCODE
  }
  '-gui' {
    Invoke-Clean
    $rc = Invoke-Compile
    if ($rc -ne 0) { exit $rc }
    Write-Host "-------------------------------"
    Write-Host "- Running Simulation"
    Write-Host "-------------------------------"
    & vvp my_sim_exe +kat=kat_vectors.txt +dump
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if (Get-Command gtkwave -ErrorAction SilentlyContinue) {
      Write-Host "-------------------------------"
      Write-Host "- Opening Wave"
      Write-Host "-------------------------------"
      & gtkwave simulation.vcd
      exit $LASTEXITCODE
    }
    Write-Host "gtkwave not installed - wave written to simulation.vcd, open it with your viewer."
    exit 0
  }
  '-modelsim' {
    Write-Host "ModelSim is not installed on this host - use: .\run.ps1 $top -dump"
    exit 1
  }
  '-modelsim_gui' {
    Write-Host "ModelSim is not installed on this host - use: .\run.ps1 $top -dump"
    exit 1
  }
  default { Show-Error; exit 1 }
}
