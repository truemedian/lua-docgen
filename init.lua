-- LuaFormatter off

--[=[ Class
@class {class-name}         -- The class's name
@inherits {base-class-name} -- A base class that this class inherits from (may be multiple)
@tag {name}                 -- A class tag (may be multiple)
@methodtag {name}           -- A method tag that will be applied to *all* methods (may be multiple)
@description {...}          -- A description of the class
]=]

--[=[ Class Constructor
@constructor __init         		-- The constructor's name (this should always be named __init)
@param {name} {type}        		-- A required parameter (may be multiple)
@param? {name} {type}       		-- An optional parameter (may be multiple)
@tag {name}                 		-- A constructor tag (may be multiple)
@description {...}          		-- A description of the constructor
]=]

--[=[ Metamethod
@metamethod {metamethod}    		-- The metamethod's name (prefixed with __)
@description {...}          		-- A description of any specific behavior this metamethod has
]=]

--[=[ Static Method
@static {method-name}       		-- The static method's name
@param {name} {type}        		-- A required parameter (may be multiple)
@param? {name} {type} {default?}	-- An optional parameter (may be multiple)
@tag {name}                 		-- A method tag (may be multiple)
@returns {type}             		-- A return value from the method (may be multiple)
@description {...}          		-- A description of the method
]=]

--[=[ Method
@method {method-name}       		-- The method's name
@param {name} {type}        		-- A required parameter (may be multiple)
@param? {name} {type} {default?} 	-- An optional parameter (may be multiple)
@tag {name}                 		-- A method tag (may be multiple)
@returns {type}             		-- A return value from the method (may be multiple)
@description {...}          		-- A description of the method
]=]

--[=[ Property
@property {property-name}  		 	-- The property's name
@type {type}                		-- The property's type
@description {...}          		-- A description of the property
]=]

--[=[ * Available Tags
Class Tags:
- internal (this class should not be created or used by a user)
- struct (this class is a structure, and provides an interface to some internal table)
- utility (this class is a utility, and is not required in user code)

Method Tags:
- error_return (this function may return `nil, err`)
- yields (this function must be ran in a coroutine)
]=]

--[=[

Things to think about:
- should `number` types which are enumerated be marked as Enumerations#xxxxx or keep the current number type with a
	"Use xxxx enumeration for a human readable representation"

- should we add onto the syntax to allow for documenting enumerations, or continue stripping them from enums.lua

]=]

-- LuaFormatter on
local path = require 'pathjoin'
local lpeg = require 'lpeg'
local fs = require 'fs'

local lunamark_reader = require './lunamark/reader/markdown.lua'
local lunamark_writer = require './lunamark/writer/html.lua'

local lxsh = require './lxsh'

local function lua_format(str)
	return lxsh.highlighters.lua(str, {formatter = lxsh.formatters.html})
end

local function markdown(str)
	local writer = lunamark_writer.new({code_formatter = lua_format})
	local reader = lunamark_reader.new(writer, {fenced_code_blocks = true})

	return reader(str:gsub('\r', ''))
end

-- # ================== # --
-- #  Parse Docstrings  # --
-- # ================== # --

local function get_field(fields, name, fetch_value)
	for _, field in ipairs(fields) do
		if field.name == name then
			return fetch_value and field.value or field
		end
	end
end

local function trim(str)
	return (str:match('^%s*(.-)%s*$'))
end

local function capture_docstring_fields(chunk)
	local fields = {}

	for name, value in chunk:gmatch('@(%S+)%s+([^@]+)') do
		fields[#fields + 1] = {_name = name, name = name, value = trim(value)}
	end

	return fields
end

local patterns = {}
do
	local C, Cg, Cp, Ct, P, S, V = lpeg.C, lpeg.Cg, lpeg.Cp, lpeg.Ct, lpeg.P, lpeg.S, lpeg.V
	lpeg.locale(lpeg)

	local type_name = C(lpeg.alnum ^ 1)
	local type_anchor = '#' * C(lpeg.alnum ^ 1)
	local type_annotation = P {'[' * C(((1 - S '[]') + V(1)) ^ 0) * ']'}

	patterns.type_plain = Ct(Cg(type_name, 'name') * Cg(type_anchor ^ -1, 'anchor'))
	patterns.type_annotated = Ct(Cg(type_name, 'name') * Cg(type_anchor ^ -1, 'anchor') * Cg(type_annotation, 'annotation'))
	patterns.type = patterns.type_annotated + patterns.type_plain
	patterns.type_list = Ct((patterns.type * ',' * lpeg.space ^ 0) ^ 0 * patterns.type) * Cp()
end

local function collect_parameters(fields)
	local params = {list = {}, simple = {}}

	params.has_optional = false
	for _, field in ipairs(fields) do
		if field.name == 'param' then
			local name, param_type = field.value:match('(%S+)%s+(.+)')

			params.list[#params.list + 1] = {name = name, types = patterns.type_list:match(param_type)}
			params.simple[#params.simple + 1] = name
		elseif field.name == 'param?' then
			local name, param_type = field.value:match('(%S+)%s+(.+)')

			local types, stop = patterns.type_list:match(param_type)

			params.has_optional = true
			params.list[#params.list + 1] = {name = name, types = types, default = trim(param_type:sub(stop + 1)), optional = true}
			params.simple[#params.simple + 1] = name
		end
	end

	return params
end

local function collect_field(fields, name, map, pattern)
	local tbl = {}

	for _, field in ipairs(fields) do
		if field.name == name then
			local value = field.value:match('(%S+)')

			if map then
				tbl[value] = true
			else
				tbl[#tbl + 1] = pattern and pattern:match(value) or value
			end
		end
	end

	return tbl
end

local function markdownify(str)
	return (str:gsub('%[%[(.-)%]%]', function(cap)
		local page, anchor = cap:match('^([^#]*)#([^#]*)$')

		if page then
			if page == '' then
				return '[' .. anchor .. '](' .. cap .. ')'
			else
				return '[' .. anchor .. '](/' .. cap .. ')'
			end
		else
			return '[' .. cap .. '](/' .. cap .. ')'
		end
	end):gsub('"', '\''))
end

local function slugify(str)
	return str:gsub('%W+', '-'):lower()
end

local function escape(str)
	return (str:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'))
end

local function parse_docstring_chunk(file_state, chunk)
	local fields = capture_docstring_fields(chunk)

	if get_field(fields, 'class') then
		local class = {}

		class.name = get_field(fields, 'class', true)
		class.inherits = collect_field(fields, 'inherits', false)
		class.description = markdownify(get_field(fields, 'description', true))

		class.tags = collect_field(fields, 'tag', true)

		class.statics = {}
		class.methods = {}
		class.metamethods = {}
		class.properties = {}

		if class.description == 'TODO' then
			print('Missing : Class       : ' .. file_state.src)
		end

		file_state.class = class
	elseif get_field(fields, 'constructor') then
		local class = assert(file_state.class, 'missing class documentation, attempted to parse constructor in: ' .. file_state.src)
		local constructor = {}

		constructor.description = markdownify(get_field(fields, 'description', true))
		constructor.params = collect_parameters(fields)

		constructor.tags = collect_field(fields, 'tag', true)

		if constructor.description == 'TODO' and (not class.tags.internal and not class.tags.abstract) then
			print('Missing : Constructor : ' .. file_state.src .. ':__init')
		end

		class.constructor = constructor
	elseif get_field(fields, 'metamethod') then
		local class = assert(file_state.class, 'missing class documentation, attempted to parse metamethod in: ' .. file_state.src)
		local metamethod = {}

		metamethod.name = get_field(fields, 'metamethod', true)
		metamethod.description = markdownify(get_field(fields, 'description', true))

		table.insert(class.metamethods, metamethod)
	elseif get_field(fields, 'method') then
		local class = assert(file_state.class, 'missing class documentation, attempted to parse method in: ' .. file_state.src)
		local method = {}

		method.name = get_field(fields, 'method', true)
		method.description = markdownify(get_field(fields, 'description', true))

		method.params = collect_parameters(fields)
		method.returns = collect_field(fields, 'returns', false, patterns.type)

		method.tags = collect_field(fields, 'tag', true)

		if method.description == 'TODO' then
			print('Missing : Method      : ' .. file_state.src .. ':' .. method.name)
		end

		table.insert(class.methods, method)
	elseif get_field(fields, 'static') then
		local class = assert(file_state.class, 'missing class documentation, attempted to parse static method in: ' .. file_state.src)
		local static = {}

		static.name = get_field(fields, 'static', true)
		static.description = markdownify(get_field(fields, 'description', true))

		static.params = collect_parameters(fields)
		static.returns = collect_field(fields, 'returns', false, patterns.type)

		static.tags = collect_field(fields, 'tag', true)

		if static.description == 'TODO' then
			print('Missing : Static      : ' .. file_state.src .. ':' .. static.name)
		end

		table.insert(class.statics, static)
	elseif get_field(fields, 'property') then
		local class = assert(file_state.class, 'missing class documentation, attempted to parse property in: ' .. file_state.src)
		local property = {}

		property.name = get_field(fields, 'property', true)
		property.types = patterns.type_list:match(get_field(fields, 'type', true))
		property.description = markdownify(get_field(fields, 'description', true))

		if property.description == 'TODO' then
			print('Missing : Property    : ' .. file_state.src .. '.' .. property.name)
		end

		table.insert(class.properties, property)
	else
		error('unknown documentation string, no identifying field')
	end
end

local function parse_file_chunk(global_state, chunk)
	local file = {src = global_state.current_file, global = global_state}

	for comment in chunk:gmatch('--%[=%[%s*(.-)%s*%]=%]') do
		parse_docstring_chunk(file, comment)
	end

	if file.class then
		global_state.classes[#global_state.classes + 1] = file.class
		global_state.classes[file.class.name] = file.class
	end
end

local function _enum_flag(n)
	return string.format('0x%x', tonumber(bit.lshift(1ULL, n)))
end

local function parse_enumerations(global_state, chunk)
	chunk = chunk:gsub('%-%-[^\n]*', '')

	local enums = global_state.enumerations or {}
	for enum, comment in chunk:gmatch('proxy.(%S+)%s*=%s*{(.-)}') do
		local tbl = {name = enum, values = {}}

		for name, value in comment:gmatch('(%S+)%s*=%s*([^,]+),') do
			local val = value:gsub('\'', '"')
			local flag = val:match('flag%((%d+)%)')

			if flag then
				val = _enum_flag(flag)
			end

			table.insert(tbl.values, {name = name, value = val})
		end

		table.insert(enums, tbl)
	end

	global_state.enumerations = enums
end

local function parse_directory(global_state, dir)
	for name, filetype in fs.scandirSync(dir) do
		if filetype == 'file' and name:sub(-4) == '.lua' then
			global_state.current_file = dir .. '/' .. name

			local content = fs.readFileSync(global_state.current_file)

			if name == 'enums.lua' then
				parse_enumerations(global_state, content)
			else
				parse_file_chunk(global_state, content)
			end
		elseif filetype == 'directory' then
			parse_directory(global_state, dir .. '/' .. name)
		end
	end
end

-- # ====================== # --
-- #  Encode Documentation  # --
-- # ====================== # --

local function make_class_section(hierarchy, name, children)
	children = hierarchy[name] or children

	if children == nil or #children == 0 then
		return {name = name}
	end

	local child_list = {}

	for i, child in ipairs(children) do
		child_list[i] = make_class_section(hierarchy, child)
	end

	return {name = name, children = child_list}
end

local function make_topic_section(name, topics)
	local child_list = {}

	for i, child in ipairs(topics) do
		if type(child) == 'table' then
			child_list[i] = {name = child[1], href = child[2]}
		else
			child_list[i] = {name = child}
		end
	end

	return {name = name, children = child_list}
end

local function collect_navigation(global_state)
	local hierarchy = {}
	local tlc = {}

	local hierarchy_filter = {Client = true, Container = true}
	for _, class in ipairs(global_state.classes) do
		if #class.inherits == 0 then
			table.insert(tlc, class.name)
			tlc[class.name] = class
		elseif not hierarchy_filter[class.name] then
			for _, parent in ipairs(class.inherits) do
				hierarchy[parent] = hierarchy[parent] or {}
				table.insert(hierarchy[parent], class.name)
				table.sort(hierarchy[parent])
			end
		end
	end

	table.sort(tlc)

	local sections = {}

	table.insert(sections, make_topic_section('Topics', {{'Home', ''}, 'Enumerations', 'Resolvable'}))

	table.insert(sections, make_class_section(hierarchy, 'Client', {'Client'}))
	table.insert(sections, make_class_section(hierarchy, 'Containers', {'Container'}))

	local utilities = {}
	local structs = {}

	for _, class in ipairs(tlc) do
		if tlc[class].tags.utility then
			table.insert(utilities, class)
		elseif tlc[class].tags.struct then
			table.insert(structs, class)
		end
	end

	table.insert(sections, make_class_section(hierarchy, 'Utilities', utilities))
	table.insert(sections, make_class_section(hierarchy, 'Structures', structs))

	return sections
end

local function collect_parents(classes, class, parents)
	for _, parent in ipairs(class.inherits) do
		if not parents[parent] then
			table.insert(parents, 1, parent)

			collect_parents(classes, classes[parent], parents)
		end
	end
end

local function collect_state(global_state)
	local classes = {}

	for _, class in ipairs(global_state.classes) do
		local parents = {}

		collect_parents(global_state.classes, class, parents)

		local properties = {}
		local statics = {}
		local methods = {}

		for _, parent in ipairs(parents) do
			local parent_class = global_state.classes[parent]

			if #parent_class.properties > 0 then
				table.sort(parent_class.properties, function(a, b)
					return a.name < b.name
				end)

				table.insert(properties, {from = parent, list = parent_class.properties})
			end

			if #parent_class.statics > 0 then
				table.sort(parent_class.statics, function(a, b)
					return a.name < b.name
				end)

				table.insert(statics, {from = parent, list = parent_class.statics})
			end

			if #parent_class.methods > 0 then
				table.sort(parent_class.methods, function(a, b)
					return a.name < b.name
				end)

				table.insert(methods, {from = parent, list = parent_class.methods})
			end
		end

		if #class.properties > 0 then
			table.sort(class.properties, function(a, b)
				return a.name < b.name
			end)

			table.insert(properties, {list = class.properties})
		end

		if #class.statics > 0 then
			table.sort(class.statics, function(a, b)
				return a.name < b.name
			end)

			table.insert(statics, {list = class.statics})
		end

		if #class.methods > 0 then
			table.sort(class.methods, function(a, b)
				return a.name < b.name
			end)

			table.insert(methods, {list = class.methods})
		end

		classes[class.name] = {description = class.description, constructor = class.constructor, properties = properties, statics = statics, methods = methods, name = class.name}
	end

	table.sort(global_state.enumerations, function(a, b)
		return a.name < b.name
	end)

	return {classes = classes, enumerations = global_state.enumerations}
end

local function write(buffer, ...)
	for i = 1, select('#', ...) do
		if buffer.needs_indent then
			for _ = 1, buffer.indent or 0 do
				table.insert(buffer, '\t')
			end

			buffer.needs_indent = false
		end

		local str = select(i, ...)
		if str:find('\n', 1, true) then
			buffer.needs_indent = true
		end

		table.insert(buffer, str)
	end
end

local function emit_type(buffer, classes, type)
	local name = type.name
	local link = type.name

	if #type.anchor > 0 then
		link = type.name .. '#' .. type.anchor
		name = type.anchor
	end

	if type.name ~= type.name:lower() then
		if classes[type.name] then
			link = '<a href="/class/' .. link .. '">' .. name .. '</a>'
		else
			link = '<a href="/' .. link .. '">' .. name .. '</a>'
		end
	end

	if type.annotation then
		local annotation

		if type.name == 'number' then
			local min, max = type.annotation:match('(%d+),%s*(%d+)')

			annotation = 'A number in the range ' .. min .. ' to ' .. max .. ', inclusive.'
		elseif type.name == 'table' then
			local key, value = type.annotation:match('(%w+),%s*(%w+)')

			if key and value then
				annotation = 'An table with ' .. key .. ' keys and ' .. value .. ' values.'
			else
				annotation = 'An array of ' .. type.annotation .. ' values.'
			end
		else
			annotation = type.annotation
		end

		write(buffer, '<span class="annotated">', '\n')
		buffer.indent = buffer.indent + 1

		write(buffer, link, '\n')
		write(buffer, '<p>', escape(annotation), '</p>')

		buffer.indent = buffer.indent - 1
		write(buffer, '</span>', '\n')
	else
		write(buffer, link)
	end
end

local function emit_types(buffer, classes, types, join)
	for i, typ in ipairs(types) do
		emit_type(buffer, classes, typ)

		if i ~= #types then
			write(buffer, join or ' or ')
		end
	end
end

local function emit_navigation_list(buffer, list, classes, this_name)
	write(buffer, '<ul>', '\n')
	buffer.indent = buffer.indent + 1

	for _, child in ipairs(list) do
		local link = child.name

		if child.href then
			link = child.href
		elseif classes[child.name] then
			link = 'class/' .. link
		end

		if child.name == this_name then
			write(buffer, '<li>', '<a class="current" href="/', link, '">', child.name, '</a>')
		else
			write(buffer, '<li>', '<a href="/', link, '">', child.name, '</a>')
		end

		buffer.indent = buffer.indent + 1

		if child.children then
			write(buffer, '\n')
			emit_navigation_list(buffer, child.children, classes, this_name)
		end

		buffer.indent = buffer.indent - 1
		write(buffer, '</li>', '\n')
	end

	buffer.indent = buffer.indent - 1
	write(buffer, '</ul>', '\n')
end

local function emit_navigation(buffer, data, this_name)
	write(buffer, '<div id="navigation">', '\n')
	buffer.indent = buffer.indent + 1

	write(buffer, '<h2>Discordia Documentation</h2>', '\n')

	for _, section in ipairs(data.nav) do
		write(buffer, '<div class="nav-section">', '\n')
		buffer.indent = buffer.indent + 1

		write(buffer, '<h3 class="section">', section.name, '</h3>', '\n')

		emit_navigation_list(buffer, section.children, data.state.classes, this_name)

		buffer.indent = buffer.indent - 1
		write(buffer, '</div>', '\n')
	end

	buffer.indent = buffer.indent - 1
	write(buffer, '</div>', '\n')

	write(buffer, '<div id="content">', '\n')
	buffer.indent = buffer.indent + 1
end

local function emit_toc(buffer, class)
	write(buffer, '<h2>Table of Contents</h2>', '\n')

	write(buffer, '<ul class="table-of-contents">', '\n')
	buffer.indent = buffer.indent + 1

	for _, obj in ipairs(class.properties) do
		write(buffer, '<li>', '\n')
		buffer.indent = buffer.indent + 1

		if obj.from then
			write(buffer, '<a href="#properties-', slugify(obj.from), '">Properties Inherited from ', obj.from, '</a>', '\n')
		else
			write(buffer, '<a href="#properties">Properties</a>', '\n')
		end

		buffer.indent = buffer.indent - 1
		write(buffer, '</li>', '\n')
	end

	for _, obj in ipairs(class.statics) do
		write(buffer, '<li>', '\n')
		buffer.indent = buffer.indent + 1

		if obj.from then
			write(buffer, '<a href="#statics-', slugify(obj.from), '">Static Methods Inherited from ', obj.from, '</a>', '\n')
		else
			write(buffer, '<a href="#statics">Static Methods</a>', '\n')
		end

		buffer.indent = buffer.indent - 1
		write(buffer, '</li>', '\n')
	end

	for _, obj in ipairs(class.methods) do
		write(buffer, '<li>', '\n')
		buffer.indent = buffer.indent + 1

		if obj.from then
			write(buffer, '<a href="#methods-', slugify(obj.from), '">Methods Inherited from ', obj.from, '</a>', '\n')
		else
			write(buffer, '<a href="#methods">Methods</a>', '\n')
		end

		buffer.indent = buffer.indent - 1
		write(buffer, '</li>', '\n')
	end

	buffer.indent = buffer.indent - 1
	write(buffer, '</ul>', '\n')
end

local function emit_sub_toc(buffer, list, prefix)
	write(buffer, '<h3>Table of Contents</h3>', '\n')

	write(buffer, '<ul class="sub-table-of-contents">', '\n')
	buffer.indent = buffer.indent + 1

	for _, obj in ipairs(list) do
		write(buffer, '<li>', '\n')
		buffer.indent = buffer.indent + 1

		write(buffer, '<a href="#', prefix .. slugify(obj.name), '">', obj.name, '</a>', '\n')

		buffer.indent = buffer.indent - 1
		write(buffer, '</li>', '\n')
	end
	
	write(buffer, '<li class="filler"></li>', '\n')

	buffer.indent = buffer.indent - 1
	write(buffer, '</ul>', '\n')
end

local function emit_parameters(buffer, classes, params)
	if #params.list > 0 then
		write(buffer, '<table class="parameters">', '\n')
		buffer.indent = buffer.indent + 1

		write(buffer, '<thead>', '\n')
		buffer.indent = buffer.indent + 1

		write(buffer, '<th>Parameter</th>', '\n')
		write(buffer, '<th>Type</th>', '\n')

		buffer.indent = buffer.indent - 1
		write(buffer, '</thead>', '\n')
		write(buffer, '<tbody>', '\n')
		buffer.indent = buffer.indent + 1

		for _, param in ipairs(params.list) do
			write(buffer, '<tr>', '\n')
			buffer.indent = buffer.indent + 1

			write(buffer, '<td>', param.name)

			if param.optional then
				write(buffer, '<abbr class="note" title="Optional">?</div>')
			end

			write(buffer, '</td>', '\n')
			write(buffer, '<td>')

			emit_types(buffer, classes, param.types)

			write(buffer, '</td>', '\n')

			buffer.indent = buffer.indent - 1
			write(buffer, '</tr>', '\n')
		end

		buffer.indent = buffer.indent - 1
		write(buffer, '</tbody>', '\n')

		buffer.indent = buffer.indent - 1
		write(buffer, '</table>', '\n')
	end
end

local function emit_class(buffer, classes, class)
	write(buffer, '<div id="class">', '\n')
	buffer.indent = buffer.indent + 1

	write(buffer, '<h1 class="name">', class.name, '</h1>', '\n')

	write(buffer, markdown(class.description), '\n')

	emit_toc(buffer, class)

	if class.constructor then
		write(buffer, '<h2 id="constructor">Constructor</h2>', '\n')
		write(buffer, '<div class="method">', '\n')
		buffer.indent = buffer.indent + 1

		write(buffer, '<h3 class="name">', '\n')
		buffer.indent = buffer.indent + 1

		write(buffer, '<a class="anchor" href="#constructor">', class.name, '(', table.concat(class.constructor.params.simple, ', '), ')</a>', '\n')

		buffer.indent = buffer.indent - 1
		write(buffer, '</h3>', '\n')

		emit_parameters(buffer, classes, class.constructor.params)

		write(buffer, '<div class="description">', '\n')
		buffer.indent = buffer.indent + 1

		write(buffer, markdown(class.constructor.description), '\n')

		buffer.indent = buffer.indent - 1
		write(buffer, '</div>', '\n')

		buffer.indent = buffer.indent - 1
		write(buffer, '</div>', '\n')
	end

	for _, props in ipairs(class.properties) do
		if props.from then
			write(buffer, '<h2 id="properties-', slugify(props.from), '">Properties Inherited from ', props.from, '</h2>', '\n')
		else
			write(buffer, '<h2 id="properties">Properties</h2>', '\n')
		end

		emit_sub_toc(buffer, props.list, 'prop-')

		write(buffer, '<table class="properties">', '\n')
		buffer.indent = buffer.indent + 1

		write(buffer, '<thead>', '\n')
		buffer.indent = buffer.indent + 1

		write(buffer, '<th>Property</th>', '\n')
		write(buffer, '<th>Type</th>', '\n')
		write(buffer, '<th>Description</th>', '\n')

		buffer.indent = buffer.indent - 1
		write(buffer, '</thead>', '\n')
		write(buffer, '<tbody>', '\n')
		buffer.indent = buffer.indent + 1

		for _, prop in ipairs(props.list) do
			write(buffer, '<tr id="prop-', slugify(prop.name), '">', '\n')
			buffer.indent = buffer.indent + 1

			write(buffer, '<td>', prop.name, '</td>', '\n')
			write(buffer, '<td>')

			emit_types(buffer, classes, prop.types)

			write(buffer, '</td>', '\n')

			write(buffer, '<td>', markdown(prop.description), '\n')

			buffer.indent = buffer.indent - 1
			write(buffer, '</tr>', '\n')
		end

		buffer.indent = buffer.indent - 1
		write(buffer, '</tbody>', '\n')

		buffer.indent = buffer.indent - 1
		write(buffer, '</table>', '\n')
	end

	for _, methods in ipairs(class.statics) do
		if methods.from then
			write(buffer, '<h2 id="statics-', slugify(methods.from), '">Static Methods Inherited from ', methods.from, '</h2>', '\n')
		else
			write(buffer, '<h2 id="statics">Static Methods</h2>', '\n')
		end

		emit_sub_toc(buffer, methods.list, 'static-')

		for _, method in ipairs(methods.list) do
			write(buffer, '<div class="method" id="static-', slugify(method.name), '">', '\n')
			buffer.indent = buffer.indent + 1

			write(buffer, '<h3 class="name">', '\n')
			buffer.indent = buffer.indent + 1

			write(buffer, '<a class="anchor" href="#static-', slugify(method.name), '">', method.name, '(', table.concat(method.params.simple, ', '), ')</a>', '\n')

			buffer.indent = buffer.indent - 1
			write(buffer, '</h3>', '\n')

			emit_parameters(buffer, classes, method.params)

			write(buffer, '<div class="description">', '\n')
			buffer.indent = buffer.indent + 1

			write(buffer, markdown(method.description), '\n')

			buffer.indent = buffer.indent - 1
			write(buffer, '</div>', '\n')

			write(buffer, '<div class="returns">', '\n')
			buffer.indent = buffer.indent + 1

			write(buffer, '<strong>Returns: </strong>')
			emit_types(buffer, classes, method.returns, ', ')
			write(buffer, '\n')

			buffer.indent = buffer.indent - 1
			write(buffer, '</div>', '\n')

			buffer.indent = buffer.indent - 1
			write(buffer, '</div>', '\n')
		end
	end

	for _, methods in ipairs(class.methods) do
		if methods.from then
			write(buffer, '<h2 id="methods-', slugify(methods.from), '">Methods Inherited from ', methods.from, '</h2>', '\n')
		else
			write(buffer, '<h2 id="methods">Methods</h2>', '\n')
		end

		emit_sub_toc(buffer, methods.list, 'method-')

		for _, method in ipairs(methods.list) do
			write(buffer, '<div class="method" id="method-', slugify(method.name), '">', '\n')
			buffer.indent = buffer.indent + 1

			write(buffer, '<h3 class="name">', '\n')
			buffer.indent = buffer.indent + 1

			write(buffer, '<a class="anchor" href="#method-', slugify(method.name), '">', method.name, '(', table.concat(method.params.simple, ', '), ')</a>', '\n')

			buffer.indent = buffer.indent - 1
			write(buffer, '</h3>', '\n')

			emit_parameters(buffer, classes, method.params)

			write(buffer, '<div class="description">', '\n')
			buffer.indent = buffer.indent + 1

			write(buffer, markdown(method.description), '\n')

			buffer.indent = buffer.indent - 1
			write(buffer, '</div>', '\n')

			write(buffer, '<div class="returns">', '\n')
			buffer.indent = buffer.indent + 1

			write(buffer, '<strong>Returns: </strong>')
			emit_types(buffer, classes, method.returns, ', ')
			write(buffer, '\n')

			buffer.indent = buffer.indent - 1
			write(buffer, '</div>', '\n')

			buffer.indent = buffer.indent - 1
			write(buffer, '</div>', '\n')
		end
	end

	buffer.indent = buffer.indent - 1
	write(buffer, '</div>', '\n')
end

local function emit_enumerations(buffer, enumerations)
	write(buffer, '<div id="enumerations">', '\n')
	buffer.indent = buffer.indent + 1

	write(buffer, '<h1 class="name">Enumerations</h1>', '\n')

	emit_sub_toc(buffer, enumerations, 'enum-')

	for _, enum in ipairs(enumerations) do
		write(buffer, '<div class="enum" id="enum-', slugify(enum.name), '">', '\n')
		buffer.indent = buffer.indent + 1

		write(buffer, '<h3 class="name">', '\n')
		buffer.indent = buffer.indent + 1

		write(buffer, '<a class="anchor" href="#enum-', slugify(enum.name), '">', enum.name, '</a>', '\n')

		buffer.indent = buffer.indent - 1
		write(buffer, '</h3>', '\n')
		write(buffer, '<table class="enumerations">', '\n')
		buffer.indent = buffer.indent + 1

		write(buffer, '<thead>', '\n')
		buffer.indent = buffer.indent + 1

		write(buffer, '<th>Name</th>', '\n')
		write(buffer, '<th>Value</th>', '\n')

		buffer.indent = buffer.indent - 1
		write(buffer, '</thead>', '\n')
		write(buffer, '<tbody>', '\n')
		buffer.indent = buffer.indent + 1

		for _, field in ipairs(enum.values) do
			write(buffer, '<tr>', '\n')
			buffer.indent = buffer.indent + 1

			write(buffer, '<td>', field.name, '</td>', '\n')
			write(buffer, '<td>', field.value, '</td>', '\n')

			buffer.indent = buffer.indent - 1
			write(buffer, '</tr>', '\n')
		end

		buffer.indent = buffer.indent - 1
		write(buffer, '</tbody>', '\n')

		buffer.indent = buffer.indent - 1
		write(buffer, '</table>', '\n')

		buffer.indent = buffer.indent - 1
		write(buffer, '</div>', '\n')
	end

	buffer.indent = buffer.indent - 1
	write(buffer, '</div>', '\n')
end

local function emit_template_begin(buffer, name)
	buffer.indent = 0
	write(buffer, '<!doctype html>', '\n')
	write(buffer, '<html>', '\n\n')

	write(buffer, '<head>', '\n')
	buffer.indent = 1

	write(buffer, '<meta charset="UTF-8">', '\n')
	write(buffer, '<meta name="viewport" content="width=device-width, initial-scale=1.0">', '\n')
	write(buffer, '<title>', 'Discordia: ', name, '</title>', '\n')
	write(buffer, '<link href="/main.css" rel="stylesheet">', '\n')

	buffer.indent = 0
	write(buffer, '</head>', '\n\n')
	write(buffer, '<body>', '\n')
	buffer.indent = 1
end

local function emit_template_end(buffer)
	buffer.indent = buffer.indent - 1
	write(buffer, '</div>', '\n')

	buffer.indent = 0
	write(buffer, '</body>', '\n\n')

	write(buffer, '</html>', '\n')
end

local bundle = require 'luvi'.bundle
local function write_documentation(global_state, src, dir)
	local navigation = collect_navigation(global_state)
	local state = collect_state(global_state)

	local data = {nav = navigation, state = state}

	fs.mkdirSync(dir)
	fs.mkdirSync(dir .. '/class')

	local buffer = {}
	for name, class in pairs(state.classes) do
		buffer = {}

		emit_template_begin(buffer, name)
		emit_navigation(buffer, data, name)
		emit_class(buffer, state.classes, class)

		emit_template_end(buffer)

		fs.writeFileSync(dir .. '/class/' .. name .. '.html', table.concat(buffer));
	end

	buffer = {}
	emit_template_begin(buffer, 'Enumerations')
	emit_navigation(buffer, data, 'Enumerations')
	emit_enumerations(buffer, state.enumerations)

	emit_template_end(buffer)

	fs.writeFileSync(dir .. '/Enumerations.html', table.concat(buffer));

	local stylesheet = assert(bundle.readfile('main.css'))
	fs.writeFileSync(dir .. '/main.css', stylesheet);

	buffer = {}
	local readme = fs.readFileSync(src .. '/../README.md') or 'Missing README'
	emit_template_begin(buffer, 'Home')
	emit_navigation(buffer, data, 'Home')
	write(buffer, markdown(readme), '\n')
	emit_template_end(buffer)

	fs.writeFileSync(dir .. '/index.html', table.concat(buffer));

	buffer = {}
	emit_template_begin(buffer, '404')
	emit_navigation(buffer, data, '404')

	write(buffer, '<h2 class="centered">Error 404</h2>', '\n')
	write(buffer, '<h3 class="centered">Page Not Found</h3>', '\n')

	emit_template_end(buffer)

	fs.writeFileSync(dir .. '/404.html', table.concat(buffer));
end

-- # =============================== # --
-- #  Scan and Parse Discordia/libs  # --
-- # =============================== # --

local function new_state()
	return {classes = {}, events = {}}
end

local docgen = {new_state = new_state, parse_file_chunk = parse_file_chunk, parse_enumerations = parse_enumerations, parse_directory = parse_directory}

if process.argv[0]:sub(-5) == 'luvit' or process.argv[0]:sub(-9) == 'luvit.exe' then
	process.argv[0] = table.remove(process.argv, 1)
end

local source = process.argv[1]
local dest = process.argv[2]

if not source or not dest then
	print('usage: ' .. process.argv[0] .. ' [source: libs/] [destination]')

	return
end

local uv = require 'uv'

print('Discordia Documentation Generator ' .. source .. ' -> ' .. dest)
print('Parsing...')

local p_start = uv.hrtime()
local state = new_state()
parse_directory(state, source)
local p_end = uv.hrtime()

print(string.format('Parsed in %.3f ms', (p_end - p_start) / 1e6))

print('Emitting...')

local e_start = uv.hrtime()
write_documentation(state, source, dest)
local e_end = uv.hrtime()

print(string.format('Emitted in %.3f ms', (e_end - e_start) / 1e6))

return docgen
