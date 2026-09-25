defmodule Pocket.Archive do
  @moduledoc false

  # erlaotc uses an ordinary stored ZIP appended to the emulator. Unlike a
  # conventional self-extracting ZIP, its offsets are absolute file offsets.
  # Delegate ZIP encoding to OTP, then relocate only those offsets.
  @eocd <<0x50, 0x4B, 0x05, 0x06>>
  @central <<0x50, 0x4B, 0x01, 0x02>>

  def executable(emulator, entries, comment) when byte_size(comment) <= 65_535 do
    names = Enum.map(entries, &elem(&1, 0))

    if length(names) != length(Enum.uniq(names)),
      do: raise(ArgumentError, "duplicate archive paths")

    if length(names) >= 65_535, do: raise(ArgumentError, "ZIP64 is not supported")
    Enum.each(names, &validate_name!/1)

    files =
      Enum.map(Enum.sort(entries), fn {name, bytes} -> {String.to_charlist(name), bytes} end)

    {:ok, {_, zip}} = :zip.create(~c"pocket.zip", files, [:memory, {:compress, []}])
    {position, count, cd_offset, cd_size, _} = directory!(zip)
    prefix_size = byte_size(emulator)

    if byte_size(zip) + prefix_size >= 0xFFFFFFFF,
      do: raise(ArgumentError, "ZIP64 is not supported")

    local = binary_part(zip, 0, cd_offset)
    central = binary_part(zip, cd_offset, cd_size)
    relocated = relocate(central, count, prefix_size, [])
    # ZIP encoding is delegated, but the final comment is the BEAM boot manifest.
    <<_::binary-size(^position), @eocd, fields::binary-size(12), _old_offset::32-little,
      _old_size::16-little, _::binary>> = zip

    IO.iodata_to_binary([
      emulator,
      local,
      relocated,
      @eocd,
      fields,
      <<cd_offset + prefix_size::32-little, byte_size(comment)::16-little>>,
      comment
    ])
  end

  def emulator!(executable) do
    {_position, count, offset, size, comment} = directory!(executable)

    unless String.starts_with?(comment, "erlaotc "),
      do: raise(ArgumentError, "not an erlaotc executable")

    central = binary_part(executable, offset, size)
    offsets = offsets(central, count, [])
    binary_part(executable, 0, Enum.min(offsets))
  end

  defp validate_name!(name) do
    if not is_binary(name) or name == "" or String.starts_with?(name, "/") or
         String.contains?(name, ["\\", "\0"]) or
         Enum.any?(String.split(name, "/"), &(&1 in ["", ".", ".."])) do
      raise ArgumentError, "unsafe archive path: #{inspect(name)}"
    end
  end

  defp directory!(binary) do
    result =
      binary
      |> :binary.matches(@eocd)
      |> Enum.reverse()
      |> Enum.find_value(fn {position, _} ->
        case binary_part(binary, position, byte_size(binary) - position) do
          <<@eocd, 0::16, 0::16, count::16-little, count::16-little, size::32-little,
            offset::32-little, length::16-little, comment::binary-size(length)>>
          when offset + size == position and count > 0 ->
            {position, count, offset, size, comment}

          _ ->
            nil
        end
      end)

    result || raise ArgumentError, "invalid or unsupported ZIP directory"
  end

  defp relocate(<<>>, 0, _prefix, acc), do: Enum.reverse(acc)

  defp relocate(binary, count, prefix, acc) when count > 0 do
    {fixed, old_offset, variable, rest} = central_entry!(binary)
    entry = [fixed, <<old_offset + prefix::32-little>>, variable]
    relocate(rest, count - 1, prefix, [entry | acc])
  end

  defp offsets(<<>>, 0, acc), do: acc

  defp offsets(binary, count, acc) when count > 0 do
    {_, offset, _, rest} = central_entry!(binary)
    offsets(rest, count - 1, [offset | acc])
  end

  defp central_entry!(
         <<@central, _::binary-size(24), name::16-little, extra::16-little, comment::16-little,
           _::binary-size(8), offset::32-little, rest::binary>> = binary
       ) do
    size = name + extra + comment
    <<variable::binary-size(^size), rest::binary>> = rest
    {binary_part(binary, 0, 42), offset, variable, rest}
  end
end
