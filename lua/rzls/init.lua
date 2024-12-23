local handlers = require("rzls.handlers")
local documentstore = require("rzls.documentstore")
local razor = require("rzls.razor")
local Log = require("rzls.log")

local M = {}

---@class rzls.Config
---@field on_attach function
---@field capabilities table
---@field path string?

--- return the path to the rzls executable
---@param config rzls.Config
---@return string
local function get_cmd_path(config)
    ---@return string
    local function get_mason_installation()
        local mason_installation = vim.fs.joinpath(vim.fn.stdpath("data") --[[@as string]], "mason", "bin", "rzls")
        return vim.uv.os_uname().sysname == "Windows_NT" and string.format("%s.cmd", mason_installation)
            or mason_installation
    end

    if config.path then
        return config.path
    end
    return get_mason_installation()
end

---@type rzls.Config
local defaultConfg = {
    on_attach = function()
        return nil
    end,
    capabilities = vim.lsp.protocol.make_client_capabilities(),
}

---@param config rzls.Config
function M.setup(config)
    Log.rzlsnvim = "Ran Setup"
    local rzlsconfig = vim.tbl_deep_extend("force", defaultConfg, config)
    rzlsconfig.path = rzlsconfig.path or get_cmd_path(rzlsconfig)
    vim.filetype.add({
        extension = {
            razor = "razor",
        },
    })

    local au = vim.api.nvim_create_augroup("rzls", { clear = true })

    vim.api.nvim_create_autocmd("FileType", {
        pattern = "razor",
        callback = function(ev)
            local root_dir = vim.fn.getcwd()
            local lsp_client_id = vim.lsp.start({
                name = "rzls",
                cmd = {
                    rzlsconfig.path,
                    "--logLevel",
                    "0",
                    "--DelegateToCSharpOnDiagnosticPublish",
                    "true",
                    "--UpdateBuffersForClosedDocuments",
                    "true",
                },
                on_init = function(client, _initialize_result)
                    documentstore.load_existing_files(client.root_dir)
                    ---@module "roslyn"
                    local roslyn_pipes = require("roslyn.server").get_pipes()
                    if roslyn_pipes[root_dir] then
                        documentstore.initialize(client)
                    else
                        vim.api.nvim_create_autocmd("User", {
                            pattern = "RoslynInitialized",
                            callback = function()
                                documentstore.initialize(client)
                            end,
                            group = au,
                        })
                    end
                    M.watch_new_files(root_dir)
                end,
                root_dir = root_dir,
                on_attach = function(client, bufnr)
                    razor.apply_highlights()
                    documentstore.register_vbufs(bufnr)
                    rzlsconfig.on_attach(client, bufnr)
                end,
                capabilities = rzlsconfig.capabilities,
                settings = {
                    html = vim.empty_dict(),
                    razor = vim.empty_dict(),
                },
                handlers = handlers,
            })

            if lsp_client_id == nil then
                vim.notify("Could not start Razor LSP", vim.log.levels.ERROR, { title = "rzls.nvim" })
                return
            end

            vim.lsp.buf_attach_client(ev.buf, lsp_client_id)

            local aftershave_client_id = vim.lsp.start({
                name = "aftershave",
                root_dir = root_dir,
                cmd = require("rzls.server.lsp").server,
            })

            if aftershave_client_id == nil then
                vim.notify("Could not start aftershave LSP", vim.log.levels.ERROR, { title = "rzls.nvim" })
                return
            end

            vim.lsp.buf_attach_client(ev.buf, aftershave_client_id)
        end,
        group = au,
    })

    vim.treesitter.language.register("html", { "razor" })

    vim.api.nvim_create_autocmd("ColorScheme", {
        group = au,
        callback = razor.apply_highlights,
    })
end

function M.watch_new_files(path)
    local w = vim.uv.new_fs_event()
    assert(w)

    local fullpath = vim.fn.fnamemodify(path, ":p")

    w:start(fullpath, {
        recursive = true,
    }, function(err, filename, _events)
        assert(not err, err)
        Log.rzlsnvim = "Filesystem changed - " .. filename
        if vim.fn.fnamemodify(filename, ":e") == "razor" then
            Log.rzlsnvim = "Filesystem changed  " .. filename .. " updating documentstore"
            vim.schedule(function()
                documentstore.register_vbufs_by_path(filename)
            end)
        end
    end)
end

return M
