b=build


build() {
	if [ -d "$b" ]; then
		echo "Found build directory"
	else 
		echo "Build directory not found, creating build diretory"
		mkdir ./build
	fi

	odin build src \
		-disallow-do \
		-warnings-as-errors \
		-vet-style \
		-vet-shadowing \
		-out:$b/MO8.bin 

	odin build src/assembler \
		-disallow-do \
		-warnings-as-errors \
		-vet-style \
		-vet-shadowing \
		-out:$b/assembler.bin 
}

clean() {
	echo "Deleting build directory"
	rm -rf ./build
}

heelp() {
	echo "usage: ./build.sh [b | c | h]"
	echo "    -b - builds the project"
	echo "    -c - cleans the project build directory"
	echo "    -h - display this help message"
}

while getopts ":hbc" opt; do
	case "$opt" in
		b|build)
			build
			;;
		c|clean)
			clean
			;;
		h|help)
			heelp
			;;
	esac
done

