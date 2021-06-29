local fs = require('fs')
local join = require('pathjoin').pathJoin

local lib = {}

lib.state = require('State')

lib.readers = {docstring2 = require('reader/Docstring2Parser'), docstring3 = require('reader/Docstring3Parser')}

lib.writers = {html = require('writer/Html')}

function lib.process_file(reader, base, file)
    if file:find('%.lua$') then
        local content = assert(fs.readFileSync(join(base, file)))

        reader:load(content, file)
        reader:processFile()
    end
end

function lib.process_directory(reader, base, subdir)
    subdir = subdir or ''

    for file, kind in fs.scandirSync(join(base, subdir)) do
        if kind == 'file' then
            lib.process_file(reader, base, file)
        elseif kind == 'directory' then
            lib.process_directory(reader, base, join(subdir, file))
        end
    end
end

function lib.emit_state(writer, base)
    writer.state:prepare()

    if writer:supportsEnumerations() then
        writer:reset()

        writer:emitEnumerations()

        local buf = writer:export()
        fs.writeFileSync(join(base, writer:getPath()), buf)
    end
end

return lib
