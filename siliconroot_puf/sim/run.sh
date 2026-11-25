#!/bin/bash
# -------------------------------
# Author      : najamdesktop\najam
# Description : Script for compile and running system verilog using
#               different tools like iverilog and modelsim.
# -------------------------------
# Guide
# -------------------------------
# Pre-req in order to run this
# Install iverilog | linux: sudo apt install iverilog
# Install gtkwave | linux: sudo apt install gtkwave
# run command     | ./run.sh tb_testbench_name gui
# -------------------------------
# Required Function
# -------------------------------
# cleaning stuff
cleaning_func () {
  rm -rf my_sim*
  rm -rf *.vcd
  rm -rf work
  rm -rf transcript
  rm -rf vsim.wlf
  echo "!! Files and directories created during compilation and runtime cleaned !! "
}
help () {
  echo "-------------------------------"
  echo "- HELP"
  echo "-------------------------------"
  echo "Pre-req in order to run this"
  echo "Install iverlog | linux: sudo apt install iverilog"
  echo "Install gtkwave | linux: sudo apt install gtkwave"
  echo "  run command     | ./run.sh -h or ./run.sh --help"
  echo "  run command     | ./run.sh -clean"
  echo "  run command     | ./run.sh tb_testbench_name -gui"
  echo "  dump command    | ./run.sh tb_testbench_name -dump"
  echo "  compile only    | ./run.sh tb_testbench_name -compile"
  echo "If iverilog is giving error use modelsim"
  echo "  modelsim nongui | ./run.sh tb_testbench_name -modelsim"
  echo "  compile gui     | ./run.sh tb_testbench_name -modelsim_gui"
}
error () {
  echo "-------------------------------"
  echo "Use ./run.sh -h or ./run.sh --help"
  echo "-------------------------------"
}
# -------------------------------
# Main Code
# -------------------------------
if [[ "$#" -ne 1  ||  "$#" -ne 2  ]]; then
  if [[ $1 == "-clean" ]]; then
    cleaning_func
  elif [[ $1 == "-h" || $1 == "--help" ]]; then
    help
  else
    # Build time args for IF DEF
    # args_compile+="+define+DEFINES "

    root=$(pwd)
    # Tool Command
    # The options come first and the sources last.  The Windows build of
    # Icarus Verilog stops parsing options at the first source file, so the
    # canonical form `-o my_sim_exe $1.sv -f f_list.f` fails there with
    # "-f: No such file or directory"; this order works on both hosts.
    cmd="iverilog -s $1 -g2012 -f f_list.f -o my_sim_exe $1.sv "
    # Runtime Mode
    if [[ $2 == "-gui" ]]; then
      cleaning_func
      echo "-------------------------------"
      echo "- Compiling RTL"
      echo "-------------------------------"
      $cmd
      echo "-------------------------------"
      echo "- Running Simulation"
      echo "-------------------------------"
      vvp my_sim_exe
      echo "-------------------------------"
      echo "- Opening Wave"
      echo "-------------------------------"
      gtkwave simulation.vcd
    elif [[ $2 == "-dump" ]]; then
      cleaning_func
      echo "-------------------------------"
      echo "Compiling RTL"
      echo "-------------------------------"
      $cmd
      echo "-------------------------------"
      echo "Running in dumping mode"
      echo "-------------------------------"
      vvp my_sim_exe
    elif [[ $2 == "-compile" ]]; then
      cleaning_func
      echo "-------------------------------"
      echo "Only Compiling RTL"
      echo "-------------------------------"
      $cmd
    elif [[ $2 == "-modelsim" ]]; then
      vlog -f f_list.f  $1.sv  +incdir+../rtl/
      vsim -c $1 -voptargs=+acc+$1 -do "run -a"
    elif [[ $2 == "-modelsim_gui" ]]; then
      vlog  -f f_list.f $1.sv
      vsim $1 -voptargs=+acc+$1
    else
      error
    fi
  fi
else
  error
fi
