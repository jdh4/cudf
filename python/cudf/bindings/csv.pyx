# Copyright (c) 2019, NVIDIA CORPORATION.

# cython: profile=False
# distutils: language = c++
# cython: embedsignature = True
# cython: language_level = 3

from .cudf_cpp cimport *
from .cudf_cpp import *
from cudf.bindings.csv cimport *
from libc.stdlib cimport malloc, free
from libc.stdint cimport uintptr_t
from libcpp.vector cimport vector

from cudf.bindings.types cimport table as cudf_table
from cudf.dataframe.column import Column
from cudf.dataframe.numerical import NumericalColumn
from cudf.dataframe.dataframe import DataFrame
from cudf.dataframe.datetime import DatetimeColumn
from cudf.bindings.nvtx import nvtx_range_push, nvtx_range_pop
from librmm_cffi import librmm as rmm

import nvstrings
import numpy as np
import collections.abc
import os


def is_file_like(obj):
    if not (hasattr(obj, 'read') or hasattr(obj, 'write')):
        return False
    if not hasattr(obj, "__iter__"):
        return False
    return True


_quoting_enum = {
    0: QUOTE_MINIMAL,
    1: QUOTE_ALL,
    2: QUOTE_NONNUMERIC,
    3: QUOTE_NONE,
}


cpdef cpp_read_csv(
    filepath_or_buffer, lineterminator='\n',
    quotechar='"', quoting=0, doublequote=True,
    header='infer',
    mangle_dupe_cols=True, usecols=None,
    sep=',', delimiter=None, delim_whitespace=False,
    skipinitialspace=False, names=None, dtype=None,
    skipfooter=0, skiprows=0, dayfirst=False, compression='infer',
    thousands=None, decimal='.', true_values=None, false_values=None,
    nrows=None, byte_range=None, skip_blank_lines=True, comment=None,
    na_values=None, keep_default_na=True, na_filter=True,
    prefix=None, index_col=None):

    """
    Cython function to call into libcudf API, see `read_csv`.

    See Also
    --------
    cudf.io.csv.read_csv
    """

    if delim_whitespace:
        if delimiter is not None:
            raise ValueError("cannot set both delimiter and delim_whitespace")
        if sep != ',':
            raise ValueError("cannot set both sep and delim_whitespace")

    # Alias sep -> delimiter.
    if delimiter is None:
        delimiter = sep

    nvtx_range_push("CUDF_READ_CSV", "purple")

    cdef csv_reader_args args = csv_reader_args()

    # Populate args struct
    if is_file_like(filepath_or_buffer):
        buffer = filepath_or_buffer.read()
        # check if StringIO is used
        if hasattr(buffer, 'encode'):
            args.filepath_or_buffer = buffer.encode()
        else:
            args.filepath_or_buffer = buffer
        args.input_data_form = HOST_BUFFER
    else:
        if (not os.path.isfile(filepath_or_buffer)):
            raise(FileNotFoundError)
        if (not os.path.exists(filepath_or_buffer)):
            raise(FileNotFoundError)
        args.filepath_or_buffer = filepath_or_buffer.encode()
        args.input_data_form = FILE_PATH

    if header == 'infer':
        header = -1
    header_infer = header

    if names is None:
        if header is -1:
            header_infer = 0
        if header is None:
            header_infer = -1
    else:
        if header is None:
            header_infer = -1
        for col_name in names:
            args.names.push_back(str(col_name).encode())

    if dtype is not None:
        if isinstance(dtype, collections.abc.Mapping):
            for k, v in dtype.items():
                args.dtype.push_back(str(str(k)+":"+str(v)).encode())
        elif isinstance(dtype, collections.abc.Iterable):
            for col_dtype in dtype:
                args.dtype.push_back(str(col_dtype).encode())
        else:
            msg = '''dtype must be 'list like' or 'dict' '''
            raise TypeError(msg)

    if usecols is not None:
        all_int = True
        # TODO all_of
        for col in usecols:
            if not isinstance(col, int):
                all_int = False
                break
        if all_int:
            args.use_cols_indexes = usecols
        else:
            for col_name in usecols:
                args.use_cols_names.push_back(str(col_name).encode())

    if decimal == delimiter:
        raise ValueError("decimal cannot be the same as delimiter")

    if thousands == delimiter:
        raise ValueError("thousands cannot be the same as delimiter")

    if nrows is not None and skipfooter != 0:
        raise ValueError("cannot use both nrows and skipfooter parameters")

    if byte_range is not None:
        if skipfooter != 0 or skiprows != 0 or nrows is not None:
            raise ValueError("""cannot manually limit rows to be read when
                                using the byte range parameter""")

    for value in true_values or []:
        args.true_values.push_back(str(value).encode())
    for value in false_values or []:
        args.false_values.push_back(str(value).encode())
    for value in na_values or []:
        args.na_values.push_back(str(value).encode())

    args.delimiter = delimiter.encode()[0]
    args.lineterminator = lineterminator.encode()[0]
    args.quotechar = quotechar.encode()[0]
    args.quoting = _quoting_enum[quoting]
    args.doublequote = doublequote
    args.delim_whitespace = delim_whitespace
    args.skipinitialspace = skipinitialspace
    args.dayfirst = dayfirst
    args.header = header_infer
    args.skiprows = skiprows
    args.skipfooter = skipfooter
    args.mangle_dupe_cols = mangle_dupe_cols
    if compression is not None:
        args.compression = compression.encode()
    args.decimal = decimal.encode()[0]
    args.thousands = (thousands.encode() if thousands else b'\0')[0]
    args.nrows = nrows if nrows is not None else -1
    if byte_range is not None:
        args.byte_range_offset = byte_range[0]
        args.byte_range_size = byte_range[1]
    else:
        args.byte_range_offset = 0
        args.byte_range_size = 0
    args.skip_blank_lines = skip_blank_lines
    args.comment = (comment.encode() if comment else b'\0')[0]
    args.keep_default_na = keep_default_na
    args.na_filter = na_filter
    if prefix is not None:
        args.prefix = prefix.encode()

    cdef CsvReader reader
    with nogil:
        reader = CsvReader(args)
    
    cdef cudf_table table
    table = reader.read()

    # Extract parsed columns
    outcols = []
    new_names = []
    cdef gdf_column* column
    for i in range(table.num_columns()):
        column = table.get_column(i)
        data_mem, mask_mem = gdf_column_to_column_mem(column)
        outcols.append(Column.from_mem_views(data_mem, mask_mem))
        if names is not None and isinstance(names[0], (int)):
            new_names.append(int(column.col_name.decode()))
        else:
            new_names.append(column.col_name.decode())
        free(column.col_name)
        free(column)

    # Build dataframe
    df = DataFrame()

    for k, v in zip(new_names, outcols):
        df[k] = v

    # Set index if the index_col parameter is passed
    if index_col is not None and index_col is not False:
        if isinstance(index_col, (int)):
            df = df.set_index(df.columns[index_col])
        else:
            df = df.set_index(index_col)

    nvtx_range_pop()

    return df
