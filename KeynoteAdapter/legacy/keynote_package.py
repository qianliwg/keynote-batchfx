"""Keep Keynote's UTF-8 resource names intact when rewriting ZIP packages."""
import copy
import zipfile


def open_keynote_zip(path):
    # Keynote may clear the central-directory UTF-8 flag on a later save while
    # leaving it set in local headers. Decode both paths the way Keynote does.
    try:
        return zipfile.ZipFile(path, metadata_encoding='utf-8')
    except UnicodeDecodeError:
        return zipfile.ZipFile(path)


def normalized_info(info, decoded_utf8=False):
    result = copy.copy(info)
    # Apple's ZIP writer can use UTF-8 names without setting the UTF-8 flag.
    # zipfile decodes those as CP437; writing that text back corrupts the names.
    if not decoded_utf8 and not info.flag_bits & 0x800:
        try:
            name = info.filename.encode('cp437').decode('utf-8')
        except (UnicodeEncodeError, UnicodeDecodeError):
            name = info.filename
        result.filename = name
        result.orig_filename = name
    return result
