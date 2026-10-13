cmake_minimum_required(VERSION 3.22.1)
project(exact_vector_search)

add_library(exact_vector_search SHARED exact_vector_search.cpp)
target_compile_features(exact_vector_search PRIVATE cxx_std_17)
target_compile_options(exact_vector_search PRIVATE -O3)
