# !/usr/bin/env python3
import binascii
import logging
import struct
import sys
from zlib import crc32
from math import sqrt, sin, cos, pi, atan2
import time
from re import findall
from getpass import getuser
from threading import Thread

from fluxclient.fcode.fcode_base import FcodeBase, POINT_TYPE
from fluxclient.fcode.g_to_f import GcodeToFcode
from fluxclient.hw_profile import HW_PROFILE

import cython
from libcpp.vector cimport vector
from libcpp.string cimport string

from fluxclient.utils._utils import Tools
from cpython.mem cimport PyMem_Malloc, PyMem_Realloc, PyMem_Free

logger = logging.getLogger(__name__)

cimport libc.stdlib

cdef extern from "utils_module.h": 
	ctypedef struct PathVector:
		pass
	string path_to_js(vector[vector[vector [float]]] output)
	string path_to_js_cpp(vector[vector[PathVector]]* output)

cdef extern from "path_vector.h":
	ctypedef struct PathVector:
		float x
		float y
		float z
		int path_type 

cdef class NativePath:
	cdef vector[vector[PathVector]]* ptr
	
	def __init__(self):
		pass

	cdef void setPtr(self, vector[vector[PathVector]]* pt):
		self.ptr = pt

	cdef vector[vector[PathVector]]* getPtr(self):
		return self.ptr

	def __dealloc__(self):
		PyMem_Free(self.ptr)


cdef class Tools: 
	def __init__(self):
		pass 

	cpdef path_to_js(self, path):
		cdef vector[vector[vector [float]]] origin;
		cdef NativePath native = NativePath();
		print("path_type "+str(type(path)))
		if(type(path) is type(native)):
			native = path
			return path_to_js_cpp(native.ptr)
		else:
			print("path_to_js origin called")
			return path_to_js(path)

cdef extern from "g2f_module.h":

	ctypedef enum PathType:
		pass

	cdef cppclass FCode:
		int tool;
		char absolute
		char extrude_absolute
		float unit
		float current_speed
		float G92_delta[7] 
		float time_need
		float distance
		float max_range[4]
		float filament[3]
		float previous[3]
		float current_pos[7]
		char* HEAD_TYPE
		int layer_now

		PathType path_type
		char is_cura
		vector[vector[PathVector]]* native_path

		int counter_between_layers
		float record_z

		char record_path

		int index

	int convert_to_fcode_by_line(char* line, FCode* fc, char* fcode_output);
	char* c_open_file(char* path)
	FCode* createFCodePtr()
	void trim_ends_cpp(vector[vector[PathVector]]* output);

cdef extern from "../utils/utils_module.h":
	string path_to_js_cpp(vector[vector[PathVector]]* output)

cdef class GcodeToFcodeCpp:
	cdef FCode* fc
	cdef unsigned long crc
	cdef public object image
	cdef public object md
	cdef char record_path
	cdef public object config
	cdef public object empty_layer
	cdef object path_js
	cdef object T #Thread
	cdef public str engine
	cdef public object path
	"""transform from gcode to fcode

	this should done several thing:
	  transform gcode into fcode
	  analyze metadata
	""" 
	def __init__(self, version=1, head_type="EXTRUDER", ext_metadata={}):
		self.T = None

		#super(GcodeToFcode, self).__init__()
		self.crc = 0  # computing crc32, use for generating fcode
		self.image = None  # png image that will store in fcode as perview image, should be a bytes obj

		self.path = [[[0,0,0,0]]]

		self.md = {'HEAD_TYPE': head_type, 'TIME_COST': 0, 'FILAMENT_USED': '0,0,0', 'MAX_R': 0}  # basic metadata, use extruder as default

		self.md.update(ext_metadata)

		self.record_path = True  # to speed up, set this flag to False
		self.config = None  # config dict(given from fluxstudio)
		# self.path = [[[0.0, 0.0, HW_PROFILE['model-1']['height'], POINT_TYPE['move']]]]  # recording the path extruder go through
		self.empty_layer = []
		# self.counter_between_layers = 0
		# self.record_z = 0.0
		# self.engine = 'slic3r'
		# self.now_type = POINT_TYPE['move']

		self.empty_layer = []
		self.path_js = None

	def get_metadata(self):
		"""
		Gets the metadata
		"""
		return self.md

	def get_img(self):
		"""
		Gets the preview image
		"""
		return self.image

	def header(self): 
		"""
		Returns header for fcode version 1
		"""
		return b'FC' + b'x0001' + b'\n'

	cpdef extract_vector(self, obj):
		cdef PathVector v = <PathVector> obj
		print("{" + str(v.x) + "," + str(v.y) + "}")

	cpdef sub_convert_path(self):
		# self.path_js = FcodeBase.path_to_js(self.path)
		cdef FCode* fc = self.fc
		#self.path_js = path_to_js_cpp(fc.native_path).decode()

	cpdef get_path(self, path_type='js'):
		print("warning: get_path of g2fcpp function deprecated")
		if path_type == 'js':
			self.T.join()
			if self.path_js is None:
				self.path_js = path_to_js_cpp(self.fc.native_path).decode()
			return self.path_js
		else:
			if self.path:
				return self.path
			else:
				return None

	cpdef trim_ends(self, path):
		"""
		trim the moving(non-extruding) part in path's both end
		"""
		cdef NativePath np = NativePath();
		trim_ends_cpp(self.fc.native_path)
		np.ptr = self.fc.native_path
		return np

		
	def write_metadata(self, stream):
		"""
		Writes fcode's metadata
		including a dict, and a png image
		"""
		md_join = '\x00'.join([i + '=' + self.md[i] for i in self.md]).encode()

		stream.write(struct.pack('<I', len(md_join)))
		stream.write(md_join)
		stream.write(struct.pack('<I', crc32(md_join)))

		if self.image is None:
			stream.write(struct.pack('<I', 0))
		else:
			stream.write(struct.pack('<I', len(self.image)))
			stream.write(self.image)

	def process(self, input_stream, output_stream):
		"""
		Process a input_stream consist of gcode strings and write the fcode into output_stream
		"""
		packer = lambda x: struct.pack('<B', x)  # easy alias for struct.pack('<B', x)
		packer_f = lambda x: struct.pack('<f', x)  # easy alias for struct.pack('<f', x)

		cdef char output[2048]
		cdef int script_length = 0
		cdef int output_len = 0
		cdef FCode* fc = createFCodePtr()
		self.fc = fc
		fc.tool = 0;
		print("FCode tool = " + str(<int>fc.tool))
		fc.filament[0] = 0

		try:

			print("hello");

			output_stream.write(self.header())
			output_stream.write(struct.pack('<I', 0))  # script length, will be modify in the end

			  # lengh of script block in fcode

			comment_list = []  # recorad a list of comments wrritten in gcode

			print("Start parsing gcode.")
			for line in input_stream:
				#process lines in C++
				fc.index = 12+script_length
				py_byte_string = line.encode('ascii')
				output_len = convert_to_fcode_by_line(py_byte_string, fc, output)
				output_stream.write(output[:output_len])
				script_length += output_len

			self.T = Thread(target=self.sub_convert_path)
			self.T.start()

			#update crc
			output_stream.seek(12, 0);
			print("Full length " + str(script_length))
			data = output_stream.read(script_length)
			self.crc = crc32(data);
			print("Full CRC " + str(self.crc))
			output_stream.seek(0, 2)  # 
			# write back crc and lengh info 
			output_stream.write(struct.pack('<I', self.crc))
			output_stream.seek(8, 0)
			output_stream.write(struct.pack('<I', script_length))
			output_stream.seek(0, 2)  # go back to file end

			if len(self.empty_layer) > 0 and self.empty_layer[0] == 0:  # clean up first empty layer
				self.empty_layer.pop(0)

			# warning: fileformat didn't consider multi-extruder, use first extruder instead
			#todo: test
			if fc.filament[0] and fc.HEAD_TYPE == NULL:
				self.md['HEAD_TYPE'] = 'EXTRUDER'
			elif fc.HEAD_TYPE == NULL:
				self.md['HEAD_TYPE'] = "" + fc.HEAD_TYPE
			else:
				self.md['HEAD_TYPE'] = "None";

			if self.md['HEAD_TYPE'] == 'EXTRUDER':
				self.md['FILAMENT_USED'] = ','.join(map(str, fc.filament))
				# self.md['CORRECTION'] = 'A'
				self.md['SETTING'] = str(comment_list[-137:])
			else:
				self.md['CORRECTION'] = 'N'

			self.md['TRAVEL_DIST'] = str(fc.distance)
			fc.max_range[3] = sqrt(fc.max_range[3])
			for v, k in enumerate(['X', 'Y', 'Z', 'R']):
				self.md['MAX_' + k] = str(fc.max_range[v])

			self.md['TIME_COST'] = str(fc.time_need)
			self.md['CREATED_AT'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.localtime(time.time()))
			self.md['AUTHOR'] = getuser()  # TODO: use fluxstudio user name?


			print("End of parsing gcode.")

			self.write_metadata(output_stream)

			print("End of writing meta.")

		except Exception as e:
			import traceback
			logger.info('G_to_F fail')
			traceback.print_exc(file=sys.stdout)
			return 'broken'

	def __dealloc__(self):
		PyMem_Free(self.fc)