local super = require('super')

local Reader = {}
Reader.__name = 'Reader'

function Reader.create(state)
    local self = {}

    super(self, Reader)

    self.state = state
    self.content = ''

    self.source = 'N/A'
    self.location = 0

    self.class = nil

    return self
end

function Reader:mark(index)
    local pos, last = 0, nil

    local line = 0
    repeat
        last = pos
        pos = self.content:find('\n', pos + 1, true)

        line = line + 1
    until not pos or pos >= index

    return line, index - last
end

function Reader:load(chunk, name)
    self.source = name
    self.content = chunk

    self.class = nil
end

function Reader:getName(loc)
    local row, col = self:mark(loc or self.location)

    return self.source .. ':' .. row .. ':' .. col
end

function Reader:processClass()
	return error 'processClass not implemented'
end

function Reader:processEnums()
	return error 'processEnums not implemented'
end

return Reader
