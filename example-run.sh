#!/bin/bash

# This script is suitable to run luckyluke in the background so that you can
# disconnect from the terminal or use it as a monit process group. 
#
# Asumptions, you've ...
# 
# 1. ... cloned to ~/luckyluke.
# 2. ... already run: bundle install
# 3. ... updated luckylike.yml.
# 4. ... installed rvm and ruby-2.4.2 (if not, see: https://rvm.io).

cd $HOME/luckyluke

current_pid="`/bin/cat $HOME/luckyluke/luckyluke.pid`"

# Stop the previous run, if present.
if [ "`/bin/ps -ef | /usr/bin/awk '$NF~"luckyluke" {print $2}'`" -eq $current_pid ]; then
  /bin/kill $current_pid
fi

[[ -s "$HOME/.rvm/scripts/rvm" ]] && source "$HOME/.rvm/scripts/rvm"
$HOME/.rvm/scripts/rvm use ruby-2.4.2

# Start a new process.
/usr/bin/nohup $HOME/.rvm/rubies/ruby-2.4.2/bin/ruby luckyluke.rb > luckyluke.log 2>&1 & echo $! > $HOME/luckyluke/nohup.pid
