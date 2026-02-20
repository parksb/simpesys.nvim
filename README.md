# simpesys.nvim

Neovim plugin for [Simpesys](https://github.com/parksb/simpesys).

**vim-plug**

```vim
call plug#begin()
Plug 'parksb/simpesys.nvim'
call plug#end()

lua require("simpesys").setup()
```

**lazy.nvim**

```lua
return {
  "parksb/simpesys.nvim",
  config = true,
}
```

**packer.nvim**

```lua
use {
  "parksb/simpesys.nvim",
  config = function()
    require("simpesys").setup()
  end
}
```

## License

simpesys.nvim is distributed under the [GNU General Public License v3.0](LICENSE).
