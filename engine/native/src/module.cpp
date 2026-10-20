// coastline_engine._native: C++ kernels exposed to Python with pybind11.
//
// Exposes FreeCAD's Adaptive2d (constant-engagement adaptive
// clearing, LGPL-2.1, vendored in third_party/freecad_adaptive).
// Tri-dexel simulation and arc fitting are planned here.

#include <pybind11/functional.h>
#include <pybind11/pybind11.h>
#include <pybind11/stl.h>

#include "Adaptive.hpp"

namespace py = pybind11;
using namespace AdaptivePath;

PYBIND11_MODULE(_native, m) {
    m.doc() = "Coastline native CAM kernels";

    py::enum_<OperationType>(m, "OperationType")
        .value("ClearingInside", otClearingInside)
        .value("ClearingOutside", otClearingOutside)
        .value("ProfilingInside", otProfilingInside)
        .value("ProfilingOutside", otProfilingOutside);

    py::enum_<MotionType>(m, "MotionType")
        .value("Cutting", mtCutting)
        .value("LinkClear", mtLinkClear)
        .value("LinkNotClear", mtLinkNotClear);

    py::class_<AdaptiveOutput>(m, "AdaptiveOutput")
        .def_readonly("helix_center", &AdaptiveOutput::HelixCenterPoint)
        .def_readonly("start_point", &AdaptiveOutput::StartPoint)
        .def_readonly("paths", &AdaptiveOutput::AdaptivePaths)
        .def_readonly("return_motion_type", &AdaptiveOutput::ReturnMotionType)
        .def_readonly("cleared_area", &AdaptiveOutput::ClearedArea)
        .def_readonly("start_point_not_found", &AdaptiveOutput::StartPointNotFound)
        .def_readonly("lead_path_failed", &AdaptiveOutput::LeadPathFailed)
        .def_readonly("too_many_failed_engagements", &AdaptiveOutput::TooManyFailedEngagements)
        .def_readonly("uncleared_area_remains", &AdaptiveOutput::UnclearedAreaRemains)
        .def_readonly("finishing_lead_in_failed", &AdaptiveOutput::FinishingLeadInFailed);

    py::class_<Adaptive2d>(m, "Adaptive2d")
        .def(py::init<>())
        .def_readwrite("tool_diameter", &Adaptive2d::toolDiameter)
        .def_readwrite("helix_ramp_target_diameter", &Adaptive2d::helixRampTargetDiameter)
        .def_readwrite("helix_ramp_min_diameter", &Adaptive2d::helixRampMinDiameter)
        .def_readwrite("step_over_factor", &Adaptive2d::stepOverFactor)
        .def_readwrite("tolerance", &Adaptive2d::tolerance)
        .def_readwrite("stock_to_leave", &Adaptive2d::stockToLeave)
        .def_readwrite("force_inside_out", &Adaptive2d::forceInsideOut)
        .def_readwrite("finishing_profile", &Adaptive2d::finishingProfile)
        .def_readwrite("keep_tool_down_dist_ratio", &Adaptive2d::keepToolDownDistRatio)
        .def_readwrite("op_type", &Adaptive2d::opType)
        .def(
            "execute",
            [](Adaptive2d& a, const DPaths& stock, const DPaths& paths, const DPaths& cleared) {
                py::gil_scoped_release release;
                auto out = a.Execute(stock, paths, cleared, [](TPaths) { return false; });
                return std::vector<AdaptiveOutput>(out.begin(), out.end());
            },
            py::arg("stock_paths"), py::arg("paths"), py::arg("cleared_paths") = DPaths{});
}
