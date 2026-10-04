local passed, failed = 0, 0
local original_input = vim.ui.input
local original_notify = vim.notify
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/docs/sub", "p")
root = vim.uv.fs_realpath(root)

local function test(name, fn)
	local ok, err = pcall(fn)
	vim.ui.input = original_input
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

test("opens a new buffer and creates the document only on write", function()
	local c, p, b = fixture("[[new-document]]")
	vim.ui.input = function(opts, callback)
		assert(opts.prompt:find("new-document.md", 1, true))
		assert(opts.prompt:find("? [y/N]: ", 1, true))
		assert(vim.fn.filereadable(root .. "/docs/new-document.md") == 0)
		callback("y")
	end
	local response = request(c, p, b)
	assert(vim.fn.filereadable(root .. "/docs/new-document.md") == 0)
	assert(vim.lsp.util.show_document(response.result, "utf-16", { focus = true }))
	assert(vim.api.nvim_buf_get_name(0) == root .. "/docs/new-document.md")
	assert(vim.fn.filereadable(root .. "/docs/new-document.md") == 0)
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { "# New document" })
	vim.cmd.write()
	assert(vim.fn.readfile(root .. "/docs/new-document.md")[1] == "# New document")
end)

for _, choice in ipairs({ "No", "cancel" }) do
	test(choice .. " does not create a file", function()
		local c, p, b = fixture("[[declined]]")
		vim.ui.input = function(_, callback)
			callback(choice == "No" and "n" or nil)
		end
		assert(request(c, p, b).called)
		assert(vim.fn.filereadable(root .. "/docs/declined.md") == 0)
	end)
end

test("prompts again after No and dismissal on the same client", function()
	local c, p, b = fixture("[[retry-document]]")
	local path = root .. "/docs/retry-document.md"
	local choices = { "n", "", "yes" }
	local prompts = 0
	vim.ui.input = function(opts, callback)
		prompts = prompts + 1
		assert(opts.prompt:find("retry-document.md", 1, true))
		assert(opts.prompt:find("? [y/N]: ", 1, true))
		callback(choices[prompts])
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
	assert(vim.fn.filereadable(path) == 0)
end)

test("real input keeps the full question on repeated requests", function()
	local c, p, b = fixture("[[real-input]]")
	local prompts = {}
	local autocmd = vim.api.nvim_create_autocmd("CmdlineEnter", {
		callback = function()
			prompts[#prompts + 1] = vim.fn.getcmdprompt()
		end,
	})
	local ok, err = pcall(function()
		for _ = 1, 2 do
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("n<CR>", true, false, true), "nt", false)
			local response = request(c, p, b)
			assert(response.called and response.result == nil)
		end
	end)
	vim.api.nvim_del_autocmd(autocmd)
	assert(ok, err)
	assert(#prompts == 2)
	for _, prompt in ipairs(prompts) do
		assert(prompt:find("Document does not exist. Open new buffer for ", 1, true))
		assert(prompt:find("real-input.md? [y/N]: ", 1, true))
	end
end)

test("existing LSP locations and errors pass through without prompting", function()
	local c, p, b = fixture("[[existing]]")
	vim.ui.input = function()
		error("unexpected prompt")
	end
	c.result = { uri = "file:///existing.md" }
	assert(request(c, p, b).result == c.result)
	c.result = nil
	c.err = { message = "server failed" }
	assert(request(c, p, b).err == c.err)
end)

test("non-links and inline code do not prompt", function()
	vim.ui.input = function()
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
	vim.ui.input = function(_, callback)
		callback("y")
	end
	local response = request(c, p, b)
	assert(response.result.uri == vim.uri_from_fname(root .. "/notes/nested/새문서.md"))
	local path = root .. "/notes/nested/새문서.md"
	assert(vim.fn.filereadable(path) == 0)
	assert(vim.fn.isdirectory(root .. "/notes") == 0)
	assert(vim.lsp.util.show_document(response.result, "utf-16", { focus = true }))
	assert(vim.fn.isdirectory(root .. "/notes") == 0)
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { "# 새문서" })
	vim.cmd.write()
	assert(vim.fn.readfile(path)[1] == "# 새문서")
end)

test("does not overwrite a file created while confirmation is open", function()
	local c, p, b = fixture("[[race]]")
	local path = root .. "/docs/race.md"
	vim.ui.input = function(_, callback)
		vim.fn.writefile({ "preserved" }, path)
		callback("y")
	end
	assert(request(c, p, b).result.uri == vim.uri_from_fname(path))
	assert(vim.fn.readfile(path)[1] == "preserved")
end)

test("discarding a new buffer creates neither file nor directories", function()
	local c, p, b = fixture("[[discarded/draft]]")
	vim.ui.input = function(_, callback)
		callback("y")
	end
	local response = request(c, p, b)
	assert(vim.lsp.util.show_document(response.result, "utf-16", { focus = true }))
	local draft = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(draft, 0, -1, false, { "Unsaved draft" })
	vim.ui.input = function()
		error("unexpected prompt for an open draft")
	end
	assert(request(c, p, b).result.uri == response.result.uri)
	assert(vim.api.nvim_buf_get_lines(draft, 0, -1, false)[1] == "Unsaved draft")
	vim.api.nvim_buf_delete(draft, { force = true })
	assert(vim.fn.isdirectory(root .. "/docs/discarded") == 0)
end)

test("attaching twice does not wrap the client again", function()
	local c = fixture("[[test]]")
	local wrapped = c.request
	require("simpesys.definition").attach(c)
	assert(c.request == wrapped)
end)

test("standard vim.lsp.buf.definition opens an unwritten document buffer", function()
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
	vim.ui.input = function(_, callback)
		callback("y")
	end
	local ok, err = pcall(vim.lsp.buf.definition)
	vim.lsp.get_clients = get_clients
	vim.lsp.get_client_by_id = get_client
	vim.lsp.buf_request_all = request_all
	assert(ok, err)
	assert(vim.api.nvim_buf_get_name(0) == root .. "/docs/standard-navigation.md")
	assert(vim.fn.filereadable(root .. "/docs/standard-navigation.md") == 0)
end)

vim.fn.delete(root, "rf")
print(string.format("\n  %d passed, %d failed", passed, failed))
if failed > 0 then
	vim.cmd("cquit")
end
