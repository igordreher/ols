package server

import "core:odin/parser"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:fmt"
import "core:log"
import "core:strings"
import path "core:path/slashpath"
import "core:mem"
import "core:strconv"
import "core:path/filepath"
import "core:sort"
import "core:slice"

import "shared:common"

SignatureInformationCapabilities :: struct {
	parameterInformation: ParameterInformationCapabilities,
}

SignatureHelpClientCapabilities :: struct {
	dynamicRegistration:  bool,
	signatureInformation: SignatureInformationCapabilities,
	contextSupport:       bool,
}

SignatureHelpOptions :: struct {
	triggerCharacters:   []string,
	retriggerCharacters: []string,
}

SignatureHelp :: struct {
	signatures:      []SignatureInformation,
	activeSignature: int,
	activeParameter: int,
}

SignatureInformation :: struct {
	label:         string,
	documentation: string,
	parameters:    []ParameterInformation,
}

ParameterInformation :: struct {
	label: string,
}

/*
	Lazily build the signature and returns from ast.Nodes
*/
build_symbol_signature :: proc(symbol: ^Symbol) {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, symbol.signature)
	defer symbol.signature = strings.to_string(builder)

	if value, ok := symbol.value.(SymbolProcedureValue); ok {
		strings.write_string(&builder, "proc")
		strings.write_string(&builder, "(")
		for arg, i in value.arg_types {
			strings.write_string(&builder, common.node_to_string(arg))
			if i != len(value.arg_types) - 1 {
				strings.write_string(&builder, ", ")
			}
		}
		strings.write_string(&builder, ")")

		if len(value.return_types) != 0 {
			strings.write_string(&builder, " -> ")

			if len(value.return_types) > 1 {
				strings.write_string(&builder, "(")
			}

			for arg, i in value.return_types {
				strings.write_string(&builder, common.node_to_string(arg))
				if i != len(value.return_types) - 1 {
					strings.write_string(&builder, ", ")
				}
			}

			if len(value.return_types) > 1 {
				strings.write_string(&builder, ")")
			}
		}
	} else if value, ok := symbol.value.(SymbolAggregateValue); ok {
		strings.write_string(&builder, "proc")
	} else if value, ok := symbol.value.(SymbolStructValue); ok {
		if symbol.signature != "struct" {
			strings.write_string(&builder, " :: struct")
		}
		strings.write_string(&builder, " {")
		for name, i in value.names {
			type := common.node_to_string(value.types[i])
			strings.write_string(&builder, fmt.tprintf("\n\t%s: %s,", name, type))
		}
		strings.write_string(&builder, "\n}")
	} else if value, ok := symbol.value.(SymbolUnionValue); ok {
		if symbol.signature != "union" {
			strings.write_string(&builder, " :: union")
		}
		strings.write_string(&builder, " {")
		for type, i in value.types {
			strings.write_string(&builder, fmt.tprintf("\n\t%s,", common.node_to_string(type)))
		}
		strings.write_string(&builder, "\n}")
	} else if value, ok := symbol.value.(SymbolEnumValue); ok {
		if symbol.signature != "enum" {
			strings.write_string(&builder, " :: enum")
		}
		strings.write_string(&builder, " {")
		for name, i in value.names {
			strings.write_string(&builder, fmt.tprintf("\n\t%s,", name))
		}
		strings.write_string(&builder, "\n}")
	}
}

seperate_proc_field_arguments :: proc(procedure: ^Symbol) {
	if value, ok := &procedure.value.(SymbolProcedureValue); ok {
		types := make([dynamic]^ast.Field, context.temp_allocator)

		for arg, i in value.arg_types {
			if len(arg.names) == 1 {
				append(&types, arg)
				continue
			}

			for name in arg.names {
				field: ^ast.Field = new_type(
					ast.Field,
					arg.pos,
					arg.end,
					context.temp_allocator,
				)
				field.names = make([]^ast.Expr, 1, context.temp_allocator)
				field.names[0] = name
				field.type = arg.type
				append(&types, field)
			}
		}

		value.arg_types = types[:]
	}
}

get_signature_information :: proc(
	document: ^Document,
	position: common.Position,
) -> (
	SignatureHelp,
	bool,
) {
	signature_help: SignatureHelp

	ast_context := make_ast_context(
		document.ast,
		document.imports,
		document.package_name,
		document.uri.uri,
		document.fullpath,
	)

	position_context, ok := get_document_position_context(
		document,
		position,
		.SignatureHelp,
	)

	if !ok {
		return signature_help, true
	}

	//TODO(should probably not be an ast.Expr, but ast.Call_Expr)
	if position_context.call == nil {
		return signature_help, true
	}

	get_globals(document.ast, &ast_context)

	if position_context.function != nil {
		get_locals(
			document.ast,
			position_context.function,
			&ast_context,
			&position_context,
		)
	}

	for comma, i in position_context.call_commas {
		if position_context.position > comma {
			signature_help.activeParameter = i + 1
		} else if position_context.position == comma {
			signature_help.activeParameter = i
		}
	}

	if position_context.arrow {
		signature_help.activeParameter += 1
	}

	call: Symbol
	call, ok = resolve_type_expression(&ast_context, position_context.call)

	if !ok {
		return signature_help, true
	}

	seperate_proc_field_arguments(&call)

	signature_information := make(
		[dynamic]SignatureInformation,
		context.temp_allocator,
	)

	if value, ok := call.value.(SymbolProcedureValue); ok {
		parameters := make(
			[]ParameterInformation,
			len(value.arg_types),
			context.temp_allocator,
		)

		for arg, i in value.arg_types {
			if arg.type != nil {
				if _, is_ellipsis := arg.type.derived.(^ast.Ellipsis);
				   is_ellipsis {
					signature_help.activeParameter = min(
						i,
						signature_help.activeParameter,
					)
				}
			}

			parameters[i].label = common.node_to_string(arg)
		}

		build_symbol_signature(&call)

		info := SignatureInformation {
			label         = concatenate_symbol_information(
				&ast_context,
				call,
				false,
			),
			documentation = call.doc,
			parameters    = parameters,
		}
		append(&signature_information, info)
	} else if value, ok := call.value.(SymbolAggregateValue); ok {
		//function overloaded procedures
		for symbol in value.symbols {
			symbol := symbol

			if value, ok := symbol.value.(SymbolProcedureValue); ok {
				parameters := make(
					[]ParameterInformation,
					len(value.arg_types),
					context.temp_allocator,
				)

				for arg, i in value.arg_types {
					if arg.type != nil {
						if _, is_ellipsis := arg.type.derived.(^ast.Ellipsis);
						   is_ellipsis {
							signature_help.activeParameter = min(
								i,
								signature_help.activeParameter,
							)
						}
					}

					parameters[i].label = common.node_to_string(arg)
				}

				build_symbol_signature(&symbol)

				info := SignatureInformation {
					label         = concatenate_symbol_information(
						&ast_context,
						symbol,
						false,
					),
					documentation = symbol.doc,
				}

				append(&signature_information, info)
			}
		}
	}

	signature_help.signatures = signature_information[:]

	return signature_help, true
}
