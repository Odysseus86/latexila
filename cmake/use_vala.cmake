##
# Copyright 2009-2010 Jakob Westhoff. All rights reserved.
# Copyright 2010-2011 Daniel Pfeifer
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
#	1. Redistributions of source code must retain the above copyright notice,
#	   this list of conditions and the following disclaimer.
#
#	2. Redistributions in binary form must reproduce the above copyright notice,
#	   this list of conditions and the following disclaimer in the documentation
#	   and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY JAKOB WESTHOFF ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
# EVENT SHALL JAKOB WESTHOFF OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
# OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
# ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
# The views and conclusions contained in the software and documentation are those
# of the authors and should not be interpreted as representing official policies,
# either expressed or implied, of Jakob Westhoff
##

##
# Compile vala files to their C equivalents for further processing.
#
# Adapted to better fit with LaTeXila. Original sources can be found there:
# https://github.com/jakobwesthoff/Vala_CMake
##

include(CMakeParseArguments)

function(vala_precompile)
	cmake_parse_arguments(
		ARGS
		""
		"OUTPUT;OUTPUT_DIR"
		"SOURCES;PACKAGES;VAPIS"
		${ARGN}
	)

	set(pkg_opts "")
	foreach(pkg ${ARGS_PACKAGES})
		list(APPEND pkg_opts "--pkg=${pkg}")
	endforeach()

	set(out_files "")
	foreach(src ${ARGS_SOURCES})
		get_filename_component (filename ${src} NAME_WE)
		list(APPEND out_files "${ARGS_OUTPUT_DIR}/${filename}.c")
	endforeach()

	add_custom_command(
		OUTPUT
			${out_files}
		COMMAND
			${VALA_EXECUTABLE}
			"-C"
			"-d" ${ARGS_OUTPUT_DIR}
			${pkg_opts}
			${ARGS_SOURCES}
			${ARGS_VAPIS}
		DEPENDS
			${ARGS_SOURCES}
			${ARGS_VAPIS}
	)

	set(${ARGS_OUTPUT} ${out_files} PARENT_SCOPE)
endfunction()
