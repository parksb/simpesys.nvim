local M = {}

local defaults = {
	lsp = {
		cmd = nil,
	},
}

local config = vim.deepcopy(defaults)

function M.setup(opts)
	config = vim.tbl_deep_extend("force", defaults, opts or {})
	if config.lsp.cmd then
		vim.lsp.config("simpesys", { cmd = config.lsp.cmd })
	end
	vim.lsp.enable("simpesys")
end

function M.get_cmd()
	if config.lsp.cmd then
		return config.lsp.cmd
	end
	return {
		"deno",
		"run",
		"--allow-env",
		"--allow-read",
		"--allow-write",
		"--allow-run",
		"jsr:@simpesys/lsp@0.1.1",
		"--stdio",
	}
end

function M.find_root(filepath)
	local dir = vim.fn.fnamemodify(filepath, ":p:h")

	while dir ~= "/" do
		if vim.fn.filereadable(dir .. "/simpesys.metadata.json") == 1 then
			return dir
		end

		if vim.fn.filereadable(dir .. "/deno.json") == 1 then
			local f = io.open(dir .. "/deno.json", "r")
			if f then
				local content = f:read("*a")
				f:close()
				if content:find("@simpesys/core") then
					return dir
				end
			end
		end

		dir = vim.fn.fnamemodify(dir, ":h")
	end

	return nil
end

function M.on_attach(bufnr)
	vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
end

return M
