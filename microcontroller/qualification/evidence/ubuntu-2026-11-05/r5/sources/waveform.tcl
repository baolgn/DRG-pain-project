# require parsed facilities and visible traces before reporting GUI load success.
set count [gtkwave::getNumFacs]
if {$count < 5} {error "too few waveform facilities"}
set names {}
array set present {count 0 product 0 memory_word 0}
# collect only the portable design's observable outputs.
for {set index 0} {$index < $count} {incr index} {
  set name [gtkwave::getFacName $index]
  # omit internal memory words and retain the output waveforms.
  if {[string match "*count*" $name] || [string match "*product*" $name] || [string match "*memory_word*" $name]} {
    lappend names $name
    # require each output category, not merely several aliases of one signal.
    foreach key {count product memory_word} {
      if {[string match "*$key*" $name]} {set present($key) 1}
    }
  }
}
# every independently checked output must have a loaded facility.
foreach key {count product memory_word} {
  if {!$present($key)} {error "missing waveform output $key"}
}
set added [gtkwave::addSignalsFromList $names]
if {$added < 3} {error "expected output traces were not displayed"}
puts "GTKWAVE_LOAD_PASS facilities=$count traces=$added"
gtkwave::/File/Quit
