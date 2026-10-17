# 超分服务

应用"实时超分"中"超分服务"所连接的服务端。它在一台有显卡的电脑上运行与桌面端相同的超分程序（realesrgan-ncnn-vulkan、realcugan-ncnn-vulkan）和模型；手机、平板或其他电脑把阅读中的页面按批发来，取回超分后的图片。同一组模型、倍数、降噪设置在各设备上得到相同的结果。

- 每批页面一次请求，在服务端运行一次超分程序。显卡同一时间只处理一批，其他请求按到达顺序排队。
- 页面经内存中的临时目录（默认 `/dev/shm`）交给程序，处理完立即删除。服务端不保留页面，也不保留结果。
- 服务只监听本机地址，经 Tailscale 发布给同一 tailnet 中的设备。访问控制就是 tailnet 成员身份，服务本身不设令牌，因此不要把它直接暴露到公网。

## 要求

- Linux，显卡驱动带 Vulkan（NVIDIA 的驱动自带）；
- [uv](https://docs.astral.sh/uv/)；
- Tailscale，且这台电脑与手机在同一个 tailnet 中。

## 部署

以下命令都在本目录执行。

1. 安装依赖并准备配置文件（各项说明见文件中的注释）：

   ```bash
   uv sync --frozen
   cp config.example.toml config.toml
   ```

2. 下载超分程序（GitHub 发布页上的 Linux 版，与桌面端的版本相同），解压到 `tools/`：

   ```bash
   uv run gallery-sr install-tools
   ```

   访问 GitHub 需要代理时，填写 `config.toml` 中 `[install]` 的 `proxy`。下载很慢时，也可以在别的电脑上下载 `gallery_sr/models.py` 中列出的两个 zip，放进同一个文件夹后复制过来，再运行 `uv run gallery-sr install-tools --from <该文件夹>`。

3. 试运行：

   ```bash
   uv run gallery-sr serve
   ```

   启动时每个程序先处理一张小图，日志中应出现 `realesrgan runs` 与 `realcugan runs`。出现 `does not run` 时多为 Vulkan 驱动问题，可以直接运行 `tools/realesrgan/realesrgan-ncnn-vulkan -i <一张图> -o out.jpg` 查看程序的输出。

4. 常驻运行（systemd 用户服务）。创建 `~/.config/systemd/user/gallery-sr.service`，`WorkingDirectory` 改为本目录：

   ```ini
   [Unit]
   Description=Gallery upscaling service
   After=network-online.target

   [Service]
   WorkingDirectory=%h/gallery-sr
   ExecStart=%h/gallery-sr/.venv/bin/gallery-sr serve --config config.toml
   Restart=on-failure

   [Install]
   WantedBy=default.target
   ```

   ```bash
   systemctl --user daemon-reload
   systemctl --user enable --now gallery-sr
   # 用户未登录时也运行
   loginctl enable-linger
   ```

5. 发布到 tailnet（端口与 `config.toml` 中的 `port` 一致）：

   ```bash
   tailscale serve --bg --https=8790 http://127.0.0.1:8790
   ```

   服务地址为 `https://<机器名>.<tailnet 名>.ts.net:8790`。

6. 在应用中打开"设置 → 高级设置 → 图片超分辨率"，在"实时超分"一段填写"超分服务地址"，点"测试连接"，应显示显卡名称和可用模型的数量。桌面端还要打开"使用超分服务"；手机和平板只能使用超分服务。

## 接口

- `GET /v1/models`：各模型的倍数、降噪等级与能否运行，以及程序看到的显卡。
- `POST /v1/upscale?model=<id>&scale=<倍数>&denoise=<降噪等级>`：请求体是一批页面的 ZIP，每页一项，以它在这批中的序号命名（`0`、`1`……），内容为页面文件本身（JPEG、PNG 或 WebP）。返回的 ZIP 中，每个超分成功的页面有一项同名的 JPEG；无法读取、带动画或尺寸超过上限的页面没有对应项。参数不合法时返回 400，所选模型的程序不能运行时返回 503，程序出错时返回 500，均附 `{"error": "..."}`。

模型表与应用中的 `lib/src/service/sr/sr_tools.dart` 一致，修改时两边一起改。

## 测试

```bash
uv run pytest
```

测试用一个只做缩放的假程序代替超分程序，不需要显卡。
