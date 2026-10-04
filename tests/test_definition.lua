local passed, failed = 0, 0
local original_confirm = vim.fn.confirm
local original_notify = vim.notify
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/docs/sub", "p")
root = vim.uv.fs_realpath(root)

local function test(name, fn)
	local ok, err = pcall(fn)
	vim.fn.confirm = original_confirm
	vim.notify = original_notify
	if ok then
		passed = passed + 1
		print("  PASS: " .. name)
	else
		failed = failed + 1
		print("  FAIL: " .. name .. " - " .. tostring(err))
	end
end

local function fixture(line, source, opts)
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(buf)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
	local client = {
		config = { root_dir = root, init_options = opts },
		offset_encoding = "utf-16",
		request = function(self, _, _, handler, bufnr)
			self.pending = function()
				handler(self.err, self.result, { bufnr = bufnr })
			end
			return true, 42
		end,
	}
	require("simpesys.definition").attach(client)
	local params = {
		textDocument = { uri = vim.uri_from_fname(root .. "/" .. (source or "docs/index.md")) },
		position = { line = 0, character = 3 },
	}
	return client, params, buf
end

local function request(client, params, buf)
	local received = {}
	local ok, id = client:request("textDocument/definition", params, function(err, result)
		received.called = true
		received.err = err
		received.result = result
	end, buf)
	assert(ok and id == 42)
	client.pending()
	return received
end

print("test_definition:")

test("creates missing document from unsaved text and returns navigation location", function()
	local c, p, b = fixture("[[new-document]]")
	vim.fn.confirm = function(prompt, choices, default)
		assert(prompt:find("new-document.md", 1, true))
		assert(choices == "&Yes\n&No" and default == 2)
		assert(vim.fn.filereadable(root .. "/docs/new-document.md") == 0)
		return 1
	end
	local response = request(c, p, b)
	assert(vim.fn.filereadable(root .. "/docs/new-document.md") == 1)
	assert(vim.lsp.util.show_document(response.result, "utf-16", { focus = true }))
	assert(vim.api.nvim_buf_get_name(0) == root .. "/docs/new-document.md")
end)

for _, choice in ipairs({ "No", "cancel" }) do
	test(choice .. " does not create a file", function()
		local c, p, b = fixture("[[declined]]")
		vim.fn.confirm = function()
			return choice == "No" and 2 or 0
		end
		assert(request(c, p, b).called)
		assert(vim.fn.filereadable(root .. "/docs/declined.md") == 0)
	end)
end

test("prompts again after No and dismissal on the same client", function()
	local c, p, b = fixture("[[retry-document]]")
	local path = root .. "/docs/retry-document.md"
	local choices = { 2, 0, 1 }
	local prompts = 0
	vim.fn.confirm = function(prompt)
		prompts = prompts + 1
		assert(prompt:find("retry-document.md", 1, true))
		return choices[prompts]
	end
	for attempt = 1, 2 do
		local response = request(c, p, b)
		assert(response.called and response.result == nil)
		assert(prompts == attempt)
		assert(vim.fn.filereadable(path) == 0)
	end
	local response = request(c, p, b)
	assert(prompts == 3)
	assert(response.result.uri == vim.uri_from_fname(path))
	assert(vim.fn.filereadable(path) == 1)
end)

test("existing LSP locations and errors pass through without prompting", function()
	local c, p, b = fixture("[[existing]]")
	vim.fn.confirm = function()
		error("unexpected prompt")
	end
	c.result = { uri = "file:///existing.md" }
	assert(request(c, p, b).result == c.result)
	c.result = nil
	c.err = { message = "server failed" }
	assert(request(c, p, b).err == c.err)
end)

test("non-links and inline code do not prompt", function()
	vim.fn.confirm = function()
		error("unexpected prompt")
	end
	for _, line in ipairs({ "plain text", "`[[code]]`" }) do
		local c, p, b = fixture(line)
		assert(request(c, p, b).result == nil)
	end
end)

test("relative paths, custom docs directory, labels and UTF-16 positions", function()
	local c, p, b = fixture("한글 😀 [[../nested/새문서|이름]]", "notes/sub/index.md", {
		docsDir = "notes",
		linkStyle = "obsidian",
	})
	p.position.character = 10
	c.result = {}
	vim.fn.confirm = function()
		return 1
	end
	local response = request(c, p, b)
	assert(response.result.uri == vim.uri_from_fname(root .. "/notes/nested/새문서.md"))
	assert(vim.fn.filereadable(root .. "/notes/nested/새문서.md") == 1)
end)

test("does not overwrite a file created while confirmation is open", function()
	local c, p, b = fixture("[[race]]")
	local path = root .. "/docs/race.md"
	vim.fn.confirm = function()
		vim.fn.writefile({ "preserved" }, path)
		return 1
	end
	assert(request(c, p, b).result.uri == vim.uri_from_fname(path))
	assert(vim.fn.readfile(path)[1] == "preserved")
end)

test("creation errors are reported and complete the request", function()
	vim.fn.writefile({ "not a directory" }, root .. "/docs/blocked")
	local c, p, b = fixture("[[blocked/child]]")
	local notified = false
	vim.notify = function(_, level)
		notified = level == vim.log.levels.ERROR
	end
	vim.fn.confirm = function()
		return 1
	end
	local response = request(c, p, b)
	assert(notified and response.called and response.result == nil)
end)

test("attaching twice does not wrap the client again", function()
	local c = fixture("[[test]]")
	local wrapped = c.request
	require("simpesys.definition").attach(c)
	assert(c.request == wrapped)
end)

test("standard vim.lsp.buf.definition opens the created document", function()
	local c, p, b = fixture("[[standard-navigation]]")
	c.id = 123
	c.name = "simpesys"
	c.supports_method = function()
		return true
	end
	vim.api.nvim_buf_set_name(b, vim.uri_to_fname(p.textDocument.uri))
	vim.api.nvim_win_set_cursor(0, { 1, 3 })
	local get_clients = vim.lsp.get_clients
	local get_client = vim.lsp.get_client_by_id
	local request_all = vim.lsp.buf_request_all
	vim.lsp.get_clients = function()
		return { c }
	end
	vim.lsp.get_client_by_id = function()
		return c
	end
	vim.lsp.buf_request_all = function(buf, method, params, callback)
		c:request(method, type(params) == "function" and params(c) or params, function(err, result)
			callback({ [c.id] = { error = err, result = result } })
		end, buf)
		c.pending()
	end
	vim.fn.confirm = function()
		return 1
	end
	local ok, err = pcall(vim.lsp.buf.definition)
	vim.lsp.get_clients = get_clients
	vim.lsp.get_client_by_id = get_client
	vim.lsp.buf_request_all = request_all
	assert(ok, err)
	assert(vim.api.nvim_buf_get_name(0) == root .. "/docs/standard-navigation.md")
end)

vim.fn.delete(root, "rf")
print(string.format("\n  %d passed, %d failed", passed, failed))
if failed > 0 then
	vim.cmd("cquit")
end
