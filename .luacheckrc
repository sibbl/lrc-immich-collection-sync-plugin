std = "lua51"
max_line_length = false

-- Lightroom Classic SDK runtime globals.
read_globals = {
	"import",
	"_PLUGIN",
	"MAC_ENV",
	"WIN_ENV",
}

exclude_files = {
	"src/JSON.lua",
	"dist/",
}

-- Test harness globals for tests/.
files["tests/**"] = {
	globals = {
		"describe",
		"it",
		"assertEq",
		"assertTrue",
		"assertNil",
		"assertDeepEq",
		"registerLrMock",
		"resetLrMocks",
		"__lr_imports",
		"import",
		"package",
		"io",
	},
}

ignore = {
	"212", -- unused argument (common in LR callbacks and mock functions)
	"213", -- unused loop variable
	"421", -- shadowing a local variable
	"431", -- shadowing an upvalue
	"432", -- shadowing an upvalue argument
	"542", -- empty if branch
}
