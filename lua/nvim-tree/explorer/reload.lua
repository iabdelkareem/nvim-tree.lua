local utils = require "nvim-tree.utils"
local builders = require "nvim-tree.explorer.node-builders"
local common = require "nvim-tree.explorer.common"
local filters = require "nvim-tree.explorer.filters"
local sorters = require "nvim-tree.explorer.sorters"
local live_filter = require "nvim-tree.live-filter"
local notify = require "nvim-tree.notify"
local git = require "nvim-tree.git"

local M = {}

local function update_status(nodes_by_path, node_ignored, status)
  return function(node)
    if nodes_by_path[node.absolute_path] then
      common.update_git_status(node, node_ignored, status)
    end
    return node
  end
end

function M.reload(node, status)
  local cwd = node.link_to or node.absolute_path
  local handle = vim.loop.fs_scandir(cwd)
  if type(handle) == "string" then
    notify.error(handle)
    return
  end

  if node.group_next then
    node.nodes = { node.group_next }
    node.group_next = nil
  end

  local child_names = {}

  local node_ignored = node.git_status == "!!"
  local nodes_by_path = utils.key_by(node.nodes, "absolute_path")
  while true do
    local ok, name, t = pcall(vim.loop.fs_scandir_next, handle)
    if not ok or not name then
      break
    end

    local stat
    local function fs_stat_cached(path)
      if stat ~= nil then
        return stat
      end

      stat = vim.loop.fs_stat(path)
      return stat
    end

    local abs = utils.path_join { cwd, name }
    t = t or (fs_stat_cached(abs) or {}).type
    if not filters.should_ignore(abs) and not filters.should_ignore_git(abs, status.files) then
      child_names[abs] = true

      -- Recreate node if type changes.
      if nodes_by_path[abs] then
        local n = nodes_by_path[abs]

        if n.type ~= t then
          utils.array_remove(node.nodes, n)
          common.node_destroy(n)
          nodes_by_path[abs] = nil
        end
      end

      if not nodes_by_path[abs] then
        if t == "directory" and vim.loop.fs_access(abs, "R") then
          local folder = builders.folder(node, abs, name)
          nodes_by_path[abs] = folder
          table.insert(node.nodes, folder)
        elseif t == "file" then
          local file = builders.file(node, abs, name)
          nodes_by_path[abs] = file
          table.insert(node.nodes, file)
        elseif t == "link" then
          local link = builders.link(node, abs, name)
          if link.link_to ~= nil then
            nodes_by_path[abs] = link
            table.insert(node.nodes, link)
          end
        end
      else
        local n = nodes_by_path[abs]
        if n then
          n.executable = builders.is_executable(n.parent, abs, n.extension or "")
          n.fs_stat = fs_stat_cached(abs)
        end
      end
    end
  end

  node.nodes = vim.tbl_map(
    update_status(nodes_by_path, node_ignored, status),
    vim.tbl_filter(function(n)
      if child_names[n.absolute_path] then
        return child_names[n.absolute_path]
      else
        common.node_destroy(n)
        return nil
      end
    end, node.nodes)
  )

  local is_root = not node.parent
  local child_folder_only = common.has_one_child_folder(node) and node.nodes[1]
  if M.config.group_empty and not is_root and child_folder_only then
    node.group_next = child_folder_only
    local ns = M.reload(child_folder_only, status)
    node.nodes = ns or {}
    return ns
  end

  sorters.merge_sort(node.nodes, sorters.node_comparator)
  live_filter.apply_filter(node)
  return node.nodes
end

local function reload_and_get_git_project(path)
  local project_root = git.get_project_root(path)
  git.reload_project(project_root, path)
  return project_root, git.get_project(project_root) or {}
end

local function update_parent_statuses(node, project, root)
  while project and node and node.absolute_path ~= root do
    require("nvim-tree.explorer.common").update_git_status(node, false, project)
    node = node.parent
  end
end

function M.refresh_path(path)
  local n = utils.get_node_from_path(path)
  if not n then
    return
  end

  local node = utils.get_parent_of_group(n)
  local project_root, project = reload_and_get_git_project(path)
  M.reload(node, project)
  update_parent_statuses(node, project, project_root)

  require("nvim-tree.renderer").draw()
end

function M.setup(opts)
  M.config = opts.renderer
end

return M
