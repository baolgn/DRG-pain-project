# require parsed facilities and visible traces before reporting GUI load success.
set count [gtkwave::getNumFacs]
if {$count < 5} {error "too few waveform facilities"}
set names {}
# collect only the portable design's observable outputs.
for {set index 0} {$index < $count} {incr index} {
  set name [gtkwave::getFacName $index]
  # omit internal memory words and retain the output waveforms.
  if {[string match "*count*" $name] || [string match "*product*" $name] || [string match "*memory_word*" $name]} {
    lappend names $name
  }
}
set added [gtkwave::addSignalsFromList $names]
if {$added < 3} {error "expected output traces were not displayed"}
puts "GTKWAVE_LOAD_PASS facilities=$count traces=$added"
gtkwave::/File/Quit
