from setuptools import setup, Extension
from Cython.Build import cythonize

setup(
    name="kgdiff1",
    version="0.1.0",
    ext_modules=cythonize(
        [
            Extension(
                "kgdiff1",
                ["kgdiff1.pyx"],
            )
        ],
        language_level=3,
    ),
)
