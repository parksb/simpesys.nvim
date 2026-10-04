local M = {}

local function target_path(client, params, bufnr)
	if not params or not params.position or not params.textDocument or not vim.api.nvim_buf_is_loaded(bufnr) then
		return nil
	end
	local source = vim.uri_to_fname(params.textDocument.uri)
	local root = client.config.root_dir
	if not root then
		return nil
	end
	local opts = client.config.init_options or {}
	local docs = vim.fs.normalize(root .. "/" .. (opts.docsDir or "docs"))
	if source:sub(1, #docs + 1) ~= docs .. "/" then
		return nil
	end
	local line = vim.api.nvim_buf_get_lines(bufnr, params.position.line, params.position.line + 1, false)[1]
	if not line then
		return nil
	end
	local col = vim.str_byteindex(line, client.offset_encoding or "utf-16", params.position.character, false) + 1
	-- Match the server's treatment of inline code and link labels.
	line = line:gsub("`[^`]+`", function(code)
		return string.rep(" ", #code)
	end)
	local start = 1
	while true do
		local first, last, key = line:find("%[%[([^%]]+)%]%]", start)
		if not first then
			return nil
		end
		if opts.linkStyle == "obsidian" then
			key = key:gsub("|.+$", "")
		else
			local label_end = line:match("^%b{}()", last + 1)
			if label_end then
				last = label_end - 1
			end
		end
		if col >= first and col <= last then
			local relative = source:sub(#docs + 2)
			local dir = vim.fs.dirname(relative)
			local resolved = vim.fs.normalize(dir .. "/" .. key)
			-- Simpesys clamps relative links to the documents root.
			while resolved:sub(1, 3) == "../" do
				resolved = resolved:sub(4)
			end
			if resolved == "" or resolved == "." or resolved == ".." or resolved:find("%z") then
				return nil
			end
			return docs .. "/" .. resolved .. ".md"
		end
		start = last + 1
	end
end

local function location(path)
	return {
		uri = vim.uri_from_fname(path),
		range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
	}
end

local function create_file(path)
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	-- Exclusive creation prevents overwriting files created while the prompt was open.
	local fd, err, code = vim.uv.fs_open(path, "wx", 420)
	if not fd then
		if code == "EEXIST" and vim.fn.filereadable(path) == 1 then
			return
		end
		error(err)
	end
	local ok, close_err = vim.uv.fs_close(fd)
	if not ok then
		error(close_err)
	end
end

function M.attach(client)
	if client._simpesys_definition then
		return
	end
	client._simpesys_definition = true
	local request = client.request
	-- buf.definition supplies its own callback, so a server handler alone cannot
	-- cover standard Neovim navigation. Wrap only this client's definition requests.
	client.request = function(self, method, params, handler, bufnr)
		if method ~= "textDocument/definition" or not handler then
			return request(self, method, params, handler, bufnr)
		end
		bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
		local path = target_path(self, params, bufnr)
		return request(self, method, params, function(err, result, ctx, config)
			if err or not path or (result and next(result) ~= nil) then
				return handler(err, result, ctx, config)
			end
			if vim.fn.filereadable(path) == 1 then
				return handler(nil, location(path), ctx, config)
			end
			vim.ui.select({ "Yes", "No" }, {
				prompt = "Document does not exist. Create " .. path .. "?",
			}, function(choice)
				if choice == "Yes" then
					local ok, create_err = pcall(create_file, path)
					if ok then
						return handler(nil, location(path), ctx, config)
					end
					vim.notify("Simpesys: could not create document: " .. tostring(create_err), vim.log.levels.ERROR)
				end
				handler(err, result, ctx, config)
			end)
		end, bufnr)
	end
end

return M
