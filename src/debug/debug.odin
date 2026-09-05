/*
* Compile-time debug facilities.
*
* Everything here collapses to nothing in a release build, so debug output can
* be left at the call site permanently instead of being commented in and out.
*
*   make debug     -> ENABLED = true   (odin -debug -define:DEBUG=true)
*   make release   -> ENABLED = false  (odin -o:speed -define:DEBUG=false)
*
* Debug output goes to stderr so that it never contaminates a program's real
* stdout, and can be silenced with `2>/dev/null`.
*/
package debug

import "core:fmt"
import stdlog "core:log"
import "core:mem"

// The master switch. Defaults to whatever `-debug` was set to, so a plain
// `odin build -debug` gets debug output without any extra flags, but an
// explicit `-define:DEBUG=...` overrides that in either direction.
ENABLED :: #config(DEBUG, ODIN_DEBUG)

// Colour is switched separately from ENABLED: piping a debug dump into a file
// or a diff is much easier without escape codes in the way.
//   -define:DEBUG_COLOR=false
COLOR :: #config(DEBUG_COLOR, true)

// ANSI escape codes. These are empty strings when colour is off, so callers
// can interpolate them unconditionally and pay nothing for it.
when COLOR {
	RESET :: "\x1b[0m"
	DIM :: "\x1b[2m"
	GREY :: "\x1b[90m"
	RED :: "\x1b[31m"
	GREEN :: "\x1b[32m"
	YELLOW :: "\x1b[33m"
	BLUE :: "\x1b[34m"
	MAGENTA :: "\x1b[35m"
	CYAN :: "\x1b[36m"
	BOLD_CYAN :: "\x1b[1;36m"
} else {
	RESET :: ""
	DIM :: ""
	GREY :: ""
	RED :: ""
	GREEN :: ""
	YELLOW :: ""
	BLUE :: ""
	MAGENTA :: ""
	CYAN :: ""
	BOLD_CYAN :: ""
}

/*
* Debug trace goes through context.logger rather than straight to stderr.
*
* Writing to stderr directly is fine for a single-threaded program, but under
* `odin test` the runner draws a progress bar with ANSI redraws while worker
* threads run in parallel; a direct write that lands mid-redraw gets painted
* over, and two threads writing at once interleave inside a single line. The
* runner funnels everything logged through context.logger down a channel to one
* reporting thread instead, which is what keeps messages whole and ordered.
*
* The caller's location is forwarded so the trace still points at the call site
* rather than at this file.
*/
when ENABLED {
	log :: proc(args: ..any, sep := " ", location := #caller_location) {
		stdlog.debug(..args, sep = sep, location = location)
	}

	/*
	* printf-style variant of log.
	*/
	logf :: proc(format: string, args: ..any, location := #caller_location) {
		stdlog.debugf(format, ..args, location = location)
	}
} else {
	log :: proc(args: ..any, sep := " ", location := #caller_location) {}
	logf :: proc(format: string, args: ..any, location := #caller_location) {}
}

/*
* Heap usage tracker. A real mem.Tracking_Allocator in a debug build, an empty
* struct in a release build, so call sites need no `when` guard of their own.
*
* Usage, at the very top of main:
*
*     track: debug.Tracker
*     context.allocator = debug.track_start(&track)
*     defer debug.track_report(&track)
*
* Note that track_start cannot install the allocator itself: `context` is passed
* by implicit copy, so assigning to context.allocator inside a proc only affects
* that proc. The caller has to do the assignment with the returned allocator.
*/
when ENABLED {
	Tracker :: mem.Tracking_Allocator
} else {
	Tracker :: struct {}
}

/*
* Begins tracking, and returns the allocator the caller should install into its
* context. In a release build this hands back context.allocator unchanged.
*/
track_start :: proc(t: ^Tracker) -> mem.Allocator {
	when ENABLED {
		mem.tracking_allocator_init(t, context.allocator)
		return mem.tracking_allocator(t)
	} else {
		return context.allocator
	}
}

/*
* Prints the usage summary, then every leak and bad free with the source
* location that caused it, and tears the tracker down.
*
* This must be the FIRST defer registered in a proc: defers run last-in
* first-out, so registering it first means it runs last, after the defers that
* free the memory it is watching. Registered any later it reports live
* allocations as leaks. Note also that os.exit skips defers entirely.
*/
track_report :: proc(t: ^Tracker) {
	when ENABLED {
		logf(
			"heap: peak %.1f KiB | total %.1f KiB over %d allocs | %d freed | %d still live",
			f64(t.peak_memory_allocated) / 1024,
			f64(t.total_memory_allocated) / 1024,
			t.total_allocation_count,
			t.total_free_count,
			len(t.allocation_map),
		)
		for _, e in t.allocation_map {
			fmt.eprintfln(
				"     %sleak%s %d bytes @ %s%s(%d:%d)%s %s",
				RED,
				RESET,
				e.size,
				DIM,
				e.location.file_path,
				e.location.line,
				e.location.column,
				RESET,
				e.location.procedure,
			)
		}
		for b in t.bad_free_array {
			fmt.eprintfln(
				"     %sbad free%s %p @ %s%s(%d:%d)%s %s",
				RED,
				RESET,
				b.memory,
				DIM,
				b.location.file_path,
				b.location.line,
				b.location.column,
				RESET,
				b.location.procedure,
			)
		}
		mem.tracking_allocator_destroy(t)
	}
}
