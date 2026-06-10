b=build

odin build src \
	-disallow-do \
	-warnings-as-errors \
	-vet-style \
	-vet-shadowing \
	-out:$b/cpu.bin 
