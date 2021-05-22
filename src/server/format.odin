package server

import "shared:common"

import "core:odin/printer"

FormattingOptions :: struct {
	tabSize:                uint,
	insertSpaces:           bool, //tabs or spaces
	trimTrailingWhitespace: bool,
	insertFinalNewline:     bool,
	trimFinalNewlines:      bool,
}

DocumentFormattingParams :: struct {
	textDocument: TextDocumentIdentifier,
	options:      FormattingOptions,
}

TextEdit :: struct {
	range:   common.Range,
	newText: string,
}

get_complete_format :: proc(document: ^Document) -> ([]TextEdit, bool) {
	prnt := printer.make_printer(printer.default_style, context.temp_allocator);

	if document.ast.syntax_error_count > 0 {
		return {}, true;
	}

	if len(document.text) == 0 {
		return {}, true;
	}

	src := printer.print(&prnt, &document.ast);

	end_line     := 0;
	end_charcter := 0;

	last := document.text[0];
	line := 0;

	for current_index := 0; current_index < len(document.text); current_index += 1 {
		current := document.text[current_index];

		if last == '\r' && current == '\n' {
			line += 1;
			current_index += 1;
		} else if current == '\n' {
			line += 1;
		}

		last = current;
	}

	edit := TextEdit {
		newText = src,
		range = {
			start = {
				character = 0,
				line = 0,
			},
			end = {
				character = 1,
				line = line+1,
			},
		},
	};

	edits := make([dynamic]TextEdit, context.temp_allocator);

	append(&edits, edit);

	return edits[:], true;
}
