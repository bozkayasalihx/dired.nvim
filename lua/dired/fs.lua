-- functions for fetching files and directories information
local ut = require("dired.utils")
local config = require("dired.config")
local nui_text = require("nui.text")
local hl = require("dired.highlight")
local uv = vim.loop

local M = {}

M.path_separator = config.get("path_separator")

local access_masks = {
    S_ISVTX = 512,
    S_IRUSR = 256,
    S_IWUSR = 128,
    S_IXUSR = 64,
    S_IRGRP = 32,
    S_IWGRP = 16,
    S_IXGRP = 8,
    S_IROTH = 4,
    S_IWOTH = 2,
    S_IXOTH = 1,
}

-- is filepath a directory or just a file
function M.is_directory(filepath)
    return vim.fn.isdirectory(filepath) == 1
end

-- is filepath a hidden directory/file
function M.is_hidden(filepath)
    return filepath:sub(1, 1) == "."
end

-- get filename from absolute path
function M.get_filename(filepath)
    local fname = filepath:match("^.+" .. M.path_separator .. "(.+)$")
    if fname == nil then
        fname = string.sub(filepath, 2, #filepath)
    end
    return fname
end

function M.get_simplified_path(filepath)
    filepath = vim.fn.simplify(vim.fn.fnamemodify(filepath, ":p"))
    if filepath:sub(-1, -1) == M.path_separator then
        filepath = vim.fn.fnamemodify(filepath, ":h")
    end

    return filepath
end

-- get parent path
function M.get_parent_path(path)
    local sep = M.path_separator
    sep = sep or "/"
    return path:match("(.*" .. sep .. ")")
end

-- get absolute path
function M.get_absolute_path(path)
    if M.is_directory(path) then
        return vim.fn.fnamemodify(path, ":p")
    else
        return vim.fn.fnamemodify(path, ":h:p")
    end
end

-- join_paths
function M.join_paths(...)
    local string_builder = {}
    for _, path in ipairs({ ... }) do
        if path:sub(-1, -1) == M.path_separator then
            path = path:sub(0, -2)
        end
        table.insert(string_builder, path)
    end
    return table.concat(string_builder, M.path_separator)
end

-- structure to hold file entries
M.FsEntry = {}

-- typedef struct fs_t {
--     u32    id,       // id
--     char * filename, // file.exe
--     char * fullpath, // /tmp/file.exe
--     char * parent,   // parent directory
--     char * filetype  // filetype
--     u32    mode,     // file permissions
--     u32    nlinks,   // number of links in dir
--     u32    uid,      // user id
--     char * user,     // username
--     u32    gid,      // group id
--     char * group,    // groupname
--     u64    size,     // file size
--     char * time,     // file time
-- } FsEntry;

local FsEntry = M.FsEntry

local function get_formatted_time(stat)
    local os = require("os")
    local cdate = os.date("*t", stat.ctime.sec)
    local tdate = os.date("*t", os.time())
    local show_year = false
    local sep = nui_text("", hl.NORMAL)

    if cdate.year < tdate.year then
        show_year = true
    end

    local ftime = nil
    local month = nui_text(os.date("%6b", stat.ctime.sec), hl.MONTH)
    local day = nui_text(os.date("%e", stat.ctime.sec), hl.DAY)

    if show_year then
        ftime = nui_text(os.date("%Y  %H:%M", stat.ctime.sec))
    else
        ftime = nui_text(os.date("%m-%y %H:%M", stat.ctime.sec))
    end

    return month, day, ftime
end

local function get_type_and_access_str(fs_t)
    local filetype = "-"
    if fs_t.filetype == "directory" then
        filetype = "d"
    elseif fs_t.filetype == "link" then
        filetype = "l"
    elseif fs_t.filetype == "char" then
        filetype = "c"
    elseif fs_t.filetype == "block" then
        filetype = "b"
    elseif fs_t.filetype == "fifo" then
        filetype = "p"
    elseif fs_t.filetype == "socket" then
        filetype = "s"
    end

    local user_read = (ut.bitand(fs_t.mode, access_masks.S_IRUSR) > 0) and "r" or "-"
    local user_write = (ut.bitand(fs_t.mode, access_masks.S_IWUSR) > 0) and "w" or "-"
    local user_exec = (ut.bitand(fs_t.mode, access_masks.S_IXUSR) > 0) and "x" or "-"
    local group_read = (ut.bitand(fs_t.mode, access_masks.S_IRGRP) > 0) and "r" or "-"
    local group_write = (ut.bitand(fs_t.mode, access_masks.S_IWGRP) > 0) and "w" or "-"
    local group_exec = (ut.bitand(fs_t.mode, access_masks.S_IXGRP) > 0) and "x" or "-"
    local other_read = (ut.bitand(fs_t.mode, access_masks.S_IROTH) > 0) and "r" or "-"
    local other_write = (ut.bitand(fs_t.mode, access_masks.S_IWOTH) > 0) and "w" or "-"
    local other_exec = (ut.bitand(fs_t.mode, access_masks.S_IXOTH) > 0) and "x" or "-"

    local access_string = filetype
        .. user_read
        .. user_write
        .. user_exec
        .. group_read
        .. group_write
        .. group_exec
        .. other_read
        .. other_write

    -- sticky bit
    if ut.bitand(fs_t.mode, access_masks.S_ISVTX) > 0 then
        return access_string .. "t"
    else
        return access_string .. other_exec
    end

    return access_string
end

function FsEntry.New(id, filepath, parent_dir, filetype)
    -- create a file entry

    local stat, err = uv.fs_stat(filepath)
    if stat == nil then
        return err
    end

    local fs_t = {
        id = id,
        filename = M.get_filename(filepath),
        filepath = filepath,
        parent_dir = parent_dir,
        filetype = filetype,
        mode = stat.mode,
        nlinks = stat.nlink,
        uid = stat.uid,
        user = ut.getpwid(stat.uid).username,
        gid = stat.gid,
        group = ut.getgroupname(stat.gid).username,
        size = stat.size,
        stat = stat,
    }

    return fs_t
end

function FsEntry.Format(fs_t)
    -- format file information like dired
    local id = nui_text(string.format("%-4d", fs_t.id), hl.DIM_TEXT)
    local access_str = nui_text(string.format("%s", get_type_and_access_str(fs_t)), hl.NORMAL)
    local nlinks = nui_text(string.format("%5d", fs_t.nlinks), hl.DIM_TEXT)
    local username = nui_text(string.format("%10s", fs_t.user), hl.USERNAME)
    local size_s, size_u = ut.get_colored_short_size(fs_t.size)
    local month, day, ftime = get_formatted_time(fs_t.stat)
    local file = nil
    local sep = nui_text("", hl.NORMAL)
    if fs_t.filetype == "directory" then
        file = nui_text(string.format("%s", fs_t.filename), hl.DIRECTORY_NAME)
        sep = nui_text(M.path_separator, hl.NORMAL)
    elseif string.sub(fs_t.filename, 1, 1) == "." then
        file = nui_text(string.format("%s", fs_t.filename), hl.DOTFILE)
    else
        file = nui_text(string.format("%s", fs_t.filename), hl.FILE_NAME)
    end
    vim.b.cursor_column = #id._content
        + #access_str._content
        + #nlinks._content
        + #username._content
        + #size_s._content
        + #size_u._content
        + #month._content
        + #day._content
        + #ftime._content
        + 9
    local sp = nui_text(" ")
    return {
        id,
        sp,
        access_str,
        sp,
        nlinks,
        sp,
        username,
        sp,
        size_s,
        sp,
        size_u,
        sp,
        month,
        sp,
        day,
        sp,
        ftime,
        sp,
        file,
        sep,
    }
end

function FsEntry.RenameFile(fs_t)
    local new_name = vim.fn.input(string.format("Enter New Name (%s): ", fs_t.filename))
    local old_path = fs_t.filepath
    local new_path = M.join_paths(fs_t.parent_dir, new_name)
    local success = vim.loop.fs_rename(old_path, new_path)
    if not success then
        vim.notify(string.format('DiredRename: Could not rename "%s" to "%s".', fs_t.filename, new_name))
        return
    end
end

function FsEntry.CreateFile()
    local filename = vim.fn.input("Enter Filename: ")
    local default_dir_mode = tonumber("775", 8)
    local default_file_mode = tonumber("644", 8)

    if filename:sub(-1, -1) == M.path_separator then
        -- create a directory
        local dir = vim.b.current_dired_path
        -- print(vim.inspect(M.join_paths(dir, filename)))
        local fd = vim.loop.fs_mkdir(M.join_paths(dir, filename), default_dir_mode)

        if not fd then
            vim.notify(string.format('DiredCreate: Could not create Directory "%s".', filename))
            return
        end
    else
        local dir = vim.b.current_dired_path
        local fd, err = vim.loop.fs_open(M.join_paths(dir, filename), "w+", default_file_mode)

        if not fd then
            print(string.format('DiredCreate: Could not create file "%s".', filename))
            return
        end

        vim.loop.fs_close(fd)
    end
end

local function delete_files(path)
    local handle = vim.loop.fs_scandir(path)
    if type(handle) == "string" then
        return vim.api.nvim_err_writeln(handle)
    end

    while true do
        local name, t = vim.loop.fs_scandir_next(handle)
        if not name then
            break
        end

        local new_cwd = M.join_paths(path, name)

        if t == "directory" then
            local success = delete_files(new_cwd)
            if not success then
                return false
            end
        else
            local success = vim.loop.fs_unlink(new_cwd)

            if not success then
                return false
            end
        end
    end

    return vim.loop.fs_rmdir(path)
end

function FsEntry.DeleteFile(fs_t)
    if fs_t.filename == "." or fs_t.filename == ".." then
        vim.notify(string.format('Cannot Delete "%s"', fs_t.filepath), "error")
        return
    end
    local prompt =
        vim.fn.input(string.format("Confirm deletion of (%s) {y(es),n(o),q(uit)}: ", fs_t.filepath), "yes", "file")
    prompt = string.lower(prompt)
    if string.sub(prompt, 1, 1) == "y" then
        vim.cmd('echo "\rdeleting ... done                                                                       "')
        if fs_t.filetype == "directory" then
            delete_files(fs_t.filepath)
        else
            vim.loop.fs_unlink(fs_t.filepath)
        end
    else
        vim.notify("DiredDelete: File/Directory not deleted", "error")
    end
end
return M